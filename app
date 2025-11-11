# streamlit_app.py
import re
import json
import ast
import numpy as np
import pandas as pd
import streamlit as st
from datetime import datetime, date
from snowflake.snowpark.context import get_active_session

# ---------------------------------------------------------------------
# App title & Snowflake session
# ---------------------------------------------------------------------
st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Enhanced)")

# Snowflake session
session = get_active_session()

# Try to add openpyxl for Excel uploads
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# ---------------------------------------------------------------------
# Table Mappings (Main, Temp, and Log)
# ---------------------------------------------------------------------
main_tables = {
    "DDM_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_TEMP",
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["TARGETENTITY", "TARGETDOMAIN", "DOMAINVALUE", "DESCRIPTION"]
    },
    "DDM_XREF_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE_TEMP",
        # using same log structure for simplicity; change if different
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

# ---------------------------------------------------------------------
# Helpers: read uploaded files
# ---------------------------------------------------------------------
def read_uploaded_file(uploaded_file):
    try:
        if uploaded_file.name.endswith(".xlsx"):
            return pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            try:
                return pd.read_csv(uploaded_file, encoding="utf-8")
            except UnicodeDecodeError:
                st.warning("File is not UTF-8 encoded. Trying ISO-8859-1...")
                return pd.read_csv(uploaded_file, encoding="ISO-8859-1")
        else:
            st.error("Unsupported file format. Please upload .xlsx or .csv")
            return None
    except Exception as e:
        st.error(f"Error reading file: {e}")
        return None

# ---------------------------------------------------------------------
# Helpers: JSON cleaning + logging
# ---------------------------------------------------------------------
def clean_for_json(obj):
    """
    Convert pandas/numpy types to JSON-serializable Python types:
      - pd.NaT / np.nan -> None
      - pd.Timestamp / datetime/date -> ISO 8601 string
      - numpy integer/float/bool -> int/float/bool
      - pandas Series -> list, dict -> recursively cleaned dict
      - fallback: str(obj)
    """
    # None
    if obj is None:
        return None

    # pandas / numpy NA
    try:
        if pd.isna(obj):
            return None
    except Exception:
        pass

    # datetime-like
    if isinstance(obj, (pd.Timestamp, datetime)):
        try:
            return obj.isoformat()
        except Exception:
            return str(obj)

    if isinstance(obj, date) and not isinstance(obj, datetime):
        return obj.isoformat()

    # numpy scalars
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return float(obj)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)

    # dict -> recurse
    if isinstance(obj, dict):
        return {str(k): clean_for_json(v) for k, v in obj.items()}

    # list/tuple/set/Series -> list
    if isinstance(obj, (list, tuple, set, pd.Series)):
        return [clean_for_json(v) for v in obj]

    # native python
    if isinstance(obj, (str, int, float, bool)):
        return obj

    # fallback
    try:
        return str(obj)
    except Exception:
        return None


def log_change(table_name, action, old_value=None, new_value=None):
    """
    Clean values and insert a log row into the LOG table.
    Uses $$...$$ wrapped JSON for Snowflake-friendly multi-line content.
    """
    cleaned_old = clean_for_json(old_value) if old_value is not None else None
    cleaned_new = clean_for_json(new_value) if new_value is not None else None

    old_json = json.dumps(cleaned_old) if cleaned_old is not None else None
    new_json = json.dumps(cleaned_new) if cleaned_new is not None else None

    old_sql_val = f"$$ {old_json} $$" if old_json is not None else "NULL"
    new_sql_val = f"$$ {new_json} $$" if new_json is not None else "NULL"

    # Use the log table for domain value changes (update if you need a different log per main table)
    log_table_name = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"

    log_sql = f"""
    INSERT INTO {log_table_name}
    (action, table_name, old_value, new_value, changed_by, changed_at, approved)
    VALUES
    (
      '{action}',
      '{table_name}',
      {old_sql_val},
      {new_sql_val},
      'streamlit_user',
      CURRENT_TIMESTAMP,
      FALSE
    )
    """
    session.sql(log_sql).collect()


# ---------------------------------------------------------------------
# Helper: parse new_value / old_value from log into a dict
# ---------------------------------------------------------------------
def parse_new_value(val):
    """
    Parse a value stored in the log into a Python dict.
    Handles:
      - None / NaN
      - dicts
      - Snowflake $$...$$ wrappers
      - JSON-like strings using single quotes or unquoted keys
      - fallback to ast.literal_eval
    Raises ValueError if cannot parse to dict.
    """
    if val is None:
        raise ValueError("new_value is None")

    if isinstance(val, float) and pd.isna(val):
        raise ValueError("new_value is NaN")

    if isinstance(val, dict):
        return val

    s = str(val).strip()

    # Remove Snowflake $$ wrappers
    m = re.match(r'^\$\$(.*)\$\$$', s, flags=re.DOTALL)
    if m:
        s = m.group(1).strip()

    # Try json.loads (expects double quotes)
    try:
        parsed = json.loads(s)
        if isinstance(parsed, dict):
            return parsed
        else:
            raise ValueError("JSON parsed but result is not a dict")
    except Exception:
        pass

    # Try to fix common Python-like formats:
    # 1) Quote unquoted keys: {key: 'val'} -> {"key": 'val'}
    s_fixed = re.sub(r'([{\[,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:', r'\1"\2":', s)
    # 2) Replace single quotes with double quotes
    s_fixed = s_fixed.replace("'", '"')
    try:
        parsed = json.loads(s_fixed)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        pass

    # Last resort: ast.literal_eval
    try:
        parsed = ast.literal_eval(s)
        if isinstance(parsed, dict):
            return parsed
        else:
            raise ValueError("literal_eval did not return a dict")
    except Exception as e:
        raise ValueError(f"Could not parse value: {e}; raw={repr(val)}")


# ---------------------------------------------------------------------
# Render Table UI (for each main table)
# ---------------------------------------------------------------------
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")

        # show main table preview (catch errors)
        try:
            df = session.table(main_table).to_pandas()
            st.dataframe(df)
        except Exception as e:
            st.error(f"Could not fetch main table {main_table}: {e}")

        key_col = required_cols[-1]

        # -----------------------------------------------------------------
        # Upload Section (Insert rows into TEMP table)
        # -----------------------------------------------------------------
        st.markdown("### Upload Excel or CSV (Inserts into TEMP Table)")
        uploaded_file = st.file_uploader(f"Upload for {table_key}", type=["xlsx", "csv"])
        if uploaded_file:
            excel_df = read_uploaded_file(uploaded_file)
            if excel_df is not None:
                excel_df.columns = [col.strip().upper() for col in excel_df.columns]
                required_cols_upper = [col.upper() for col in required_cols]
                st.dataframe(excel_df.head())

                if all(col in excel_df.columns for col in required_cols_upper):
                    if st.button(f"Upload to TEMP for {table_key}"):
                        inserted = 0
                        for _, row in excel_df.iterrows():
                            # Build columns and values — convert NaN -> empty string or NULL depending on your preference
                            cols = ", ".join(required_cols_upper)
                            vals_list = []
                            for col in required_cols_upper:
                                v = row.get(col, "")
                                if pd.isna(v):
                                    vals_list.append("NULL")
                                else:
                                    sval = str(v).replace("'", "''")
                                    vals_list.append(f"'{sval}'")
                            vals = ", ".join(vals_list)
                            insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                            session.sql(insert_sql).collect()
                            # Log the insert with cleaned values
                            row_dict = {c: clean_for_json(row.get(c)) for c in required_cols_upper}
                            log_change(main_table, "INSERT", None, row_dict)
                            inserted += 1
                        st.success(f"{inserted} rows uploaded to TEMP table and logged.")
                else:
                    st.error(f"Missing columns. Required: {required_cols}")

        # -----------------------------------------------------------------
        # Manual Insert
        # -----------------------------------------------------------------
        st.subheader("Manual Insert into TEMP Table")
        with st.form(f"insert_form{table_key}"):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                cols = ", ".join(inputs.keys())
                vals = ", ".join([f"'{str(v).replace(\"'\",\"''\")}'" if v != "" else "NULL" for v in inputs.values()])
                insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                session.sql(insert_sql).collect()
                log_change(main_table, "INSERT", None, inputs)
                st.success("Record inserted into TEMP and logged.")

        # -----------------------------------------------------------------
        # Update Record (TEMP)
        # -----------------------------------------------------------------
        st.subheader("Update Record (in TEMP Table)")
        with st.form(f"update_form_{table_key}"):
            upd_key = st.text_input(f"{key_col} to Update")
            upd_col = st.selectbox("Column to Update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit_upd = st.form_submit_button("Update Record")
            if submit_upd:
                try:
                    old_val_df = session.sql(f"SELECT {upd_col} FROM {temp_table} WHERE {key_col} = '{upd_key.replace(\"'\",\"''\")}'").to_pandas()
                    old_val = old_val_df.iloc[0, 0] if not old_val_df.empty else None
                except Exception:
                    old_val = None
                update_sql = f"UPDATE {temp_table} SET {upd_col} = '{new_value.replace(\"'\",\"''\")}' WHERE {key_col} = '{upd_key.replace(\"'\",\"''\")}'"
                session.sql(update_sql).collect()
                log_change(main_table, "UPDATE", {upd_col: old_val}, {upd_col: new_value})
                st.success("Record updated in TEMP and logged.")

        # -----------------------------------------------------------------
        # Delete Record (TEMP)
        # -----------------------------------------------------------------
        st.subheader("Delete Record (from TEMP Table)")
        with st.form(f"delete_form_{table_key}"):
            del_key = st.text_input(f"{key_col} to Delete")
            confirm = st.checkbox("Confirm Delete")
            submit_del = st.form_submit_button("Delete Record")
            if submit_del and confirm:
                try:
                    old_val_df = session.sql(f"SELECT * FROM {temp_table} WHERE {key_col} = '{del_key.replace(\"'\",\"''\")}'").to_pandas()
                    old_val = old_val_df.to_dict(orient="records")[0] if not old_val_df.empty else None
                except Exception:
                    old_val = None
                delete_sql = f"DELETE FROM {temp_table} WHERE {key_col} = '{del_key.replace(\"'\",\"''\")}'"
                session.sql(delete_sql).collect()
                log_change(main_table, "DELETE", old_val, None)
                st.success("Record deleted from TEMP and logged.")
            elif submit_del:
                st.warning("Please confirm delete before proceeding.")


# ---------------------------------------------------------------------
# Approval Dashboard (global) - list pending logs and allow approvals
# ---------------------------------------------------------------------
st.markdown("## Approval Dashboard")
log_table = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"

# Fetch pending logs
try:
    pending_logs = session.sql(f"SELECT * FROM {log_table} WHERE approved = FALSE").to_pandas()
except Exception as e:
    st.error(f"Could not fetch pending logs: {e}")
    pending_logs = pd.DataFrame()

if pending_logs.empty:
    st.success("No pending approvals.")
else:
    st.warning(f"Pending Approvals: {len(pending_logs)} records found.")

    # Normalize column names
    pending_logs.columns = [c.lower() for c in pending_logs.columns]

    # Columns to display (hide internal approval metadata)
    display_cols = [c for c in pending_logs.columns if c not in ["log_id", "domain_id", "approved", "approved_by", "approved_at"]]
    display_df = pending_logs[display_cols].copy().reset_index(drop=True)

    # Add approve column if not present
    if "approve" not in display_df.columns:
        display_df["approve"] = False

    # Display using data_editor for row-level checkboxes
    edited_df = st.data_editor(
        display_df,
        use_container_width=True,
        height=400,
        column_config={
            "approve": st.column_config.CheckboxColumn(
                "Approve",
                help="Tick to approve this record",
                width=80
            )
        },
        hide_index=True
    )

    # -----------------------------------------------------------------
    # Approve selected records: replace this block with the one we designed
    # -----------------------------------------------------------------
    if st.button("Approve Selected Records"):
        to_approve = edited_df[edited_df["approve"] == True]

        if to_approve.empty:
            st.warning("No rows selected for approval.")
        else:
            approved_count = 0

            # Helper: safely escape SQL string values
            def sql_quote(v):
                if v is None:
                    return "NULL"
                s = str(v)
                return "'" + s.replace("'", "''") + "'"

            for _, log_row in to_approve.iterrows():
                # Extract fields from the edited DataFrame (columns are lowercase)
                table_name = log_row.get("table_name")
                new_value = log_row.get("new_value")
                old_value = log_row.get("old_value")
                changed_by = log_row.get("changed_by")
                changed_at = log_row.get("changed_at")
                action = log_row.get("action")

                # Find TEMP table mapping
                temp_table = None
                for key, info in main_tables.items():
                    if info.get("name") == table_name:
                        temp_table = info.get("temp")
                        break

                if not temp_table:
                    st.error(f"TEMP table not found for {table_name}")
                    continue

                try:
                    # Convert changed_at to string for SQL WHERE
                    changed_at_str = None
                    if changed_at is not None:
                        try:
                            changed_at_str = changed_at.isoformat()
                        except Exception:
                            changed_at_str = str(changed_at)
                    changed_at_sql = changed_at_str.replace("'", "''") if changed_at_str else changed_at_str

                    # Build WHERE clause to update the log row
                    where_parts = [
                        "table_name = " + sql_quote(table_name),
                        ("action = " + sql_quote(action)) if action is not None else "action IS NULL",
                        ("changed_by = " + sql_quote(changed_by)) if changed_by is not None else "changed_by IS NULL"
                    ]
                    if changed_at_sql:
                        where_parts.append(f"changed_at = '{changed_at_sql}'")
                    where_parts.append("approved = FALSE")
                    where_clause = " AND ".join(where_parts)

                    approve_sql = f"""
                        UPDATE {log_table}
                        SET approved = TRUE,
                            approved_by = 'business_user',
                            approved_at = CURRENT_TIMESTAMP
                        WHERE {where_clause}
                    """
                    session.sql(approve_sql).collect()

                    # Parse the dict from new_value/old_value depending on action
                    parsed_condition = None
                    if action and action.upper() == "DELETE":
                        if old_value:
                            try:
                                parsed_condition = parse_new_value(old_value)
                            except Exception:
                                try:
                                    parsed_condition = ast.literal_eval(old_value)
                                except Exception:
                                    parsed_condition = None
                    else:
                        if new_value:
                            try:
                                parsed_condition = parse_new_value(new_value)
                            except Exception:
                                try:
                                    parsed_condition = ast.literal_eval(new_value)
                                except Exception:
                                    parsed_condition = None

                    # Build SQL conditions for target rows
                    conditions = None
                    if isinstance(parsed_condition, dict) and parsed_condition:
                        conds = []
                        for k, v in parsed_condition.items():
                            if v is None:
                                conds.append(f"{k} IS NULL")
                            else:
                                sval = str(v).replace("'", "''")
                                conds.append(f"{k} = '{sval}'")
                        conditions = " AND ".join(conds)

                    # Apply DB actions
                    if action and action.upper() in ("INSERT", "UPDATE"):
                        if conditions:
                            insert_sql = f"INSERT INTO {table_name} SELECT * FROM {temp_table} WHERE {conditions}"
                            session.sql(insert_sql).collect()
                            session.sql(f"DELETE FROM {temp_table} WHERE {conditions}").collect()
                            approved_count += 1
                        else:
                            st.error(f"Could not construct conditions for INSERT/UPDATE for log row: {repr(log_row)}")
                            continue

                    elif action and action.upper() == "DELETE":
                        if conditions:
                            session.sql(f"DELETE FROM {temp_table} WHERE {conditions}").collect()
                            # optional: also delete from main table
                            # session.sql(f"DELETE FROM {table_name} WHERE {conditions}").collect()
                            approved_count += 1
                        else:
                            st.warning(f"Approved DELETE log but couldn't build delete condition for: {repr(log_row)}")
                            continue

                    else:
                        approved_count += 1
                        st.info(f"Log for action '{action}' approved but no DB operation performed.")

                except Exception as e:
                    st.error(f"Error approving row: {e}")
                    continue

            # After processing all rows
            st.info(f"Processed approval attempt. Successfully approved {approved_count} row(s).")

            # Refresh pending logs and preview
            try:
                refreshed_pending = session.sql(f"SELECT * FROM {log_table} WHERE approved = FALSE").to_pandas()
            except Exception as e:
                st.error(f"Could not refresh pending logs: {e}")
                refreshed_pending = pd.DataFrame()

            pending_count = len(refreshed_pending)
            if pending_count == 0:
                st.success("No more pending approvals.")
            else:
                st.warning(f"Pending Approvals (refreshed): {pending_count} record(s) found.")
                refreshed_pending.columns = [c.lower() for c in refreshed_pending.columns]
                display_cols = [c for c in refreshed_pending.columns if c not in ["log_id", "domain_id", "approved", "approved_by", "approved_at"]]
                preview_df = refreshed_pending[display_cols].copy().reset_index(drop=True)
                st.dataframe(preview_df.head(10))

            # Optional: force full rerun to refresh other UI pieces
            # st.experimental_rerun()

# ---------------------------------------------------------------------
# Tabs for Main Tables
# ---------------------------------------------------------------------
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
