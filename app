# streamlit_app.py
import re
import json
import ast
import numpy as np
import pandas as pd
import streamlit as st
from datetime import datetime, date
from snowflake.snowpark.context import get_active_session

# -------------------------
# App title & Snowflake session
# -------------------------
st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Enhanced)")

session = get_active_session()

# Try to add openpyxl for Excel uploads (best-effort)
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# -------------------------
# Table mappings
# -------------------------
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
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",  # using same log
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

# Central log table name used in the UI
LOG_TABLE = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"


# -------------------------
# Helpers: file input
# -------------------------
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


# -------------------------
# Helpers: JSON cleaning + logging
# -------------------------
def clean_for_json(obj):
    """Convert pandas/numpy types to JSON-serializable Python types."""
    if obj is None:
        return None

    try:
        if pd.isna(obj):
            return None
    except Exception:
        pass

    if isinstance(obj, (pd.Timestamp, datetime)):
        try:
            return obj.isoformat()
        except Exception:
            return str(obj)

    if isinstance(obj, date) and not isinstance(obj, datetime):
        return obj.isoformat()

    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return float(obj)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)

    if isinstance(obj, dict):
        return {str(k): clean_for_json(v) for k, v in obj.items()}

    if isinstance(obj, (list, tuple, set, pd.Series)):
        return [clean_for_json(v) for v in obj]

    if isinstance(obj, (str, int, float, bool)):
        return obj

    try:
        return str(obj)
    except Exception:
        return None


def log_change(table_name, action, old_value=None, new_value=None):
    """Write a JSON-cleaned row into the log table."""
    cleaned_old = clean_for_json(old_value) if old_value is not None else None
    cleaned_new = clean_for_json(new_value) if new_value is not None else None

    old_json = json.dumps(cleaned_old) if cleaned_old is not None else None
    new_json = json.dumps(cleaned_new) if cleaned_new is not None else None

    old_sql_val = f"$$ {old_json} $$" if old_json is not None else "NULL"
    new_sql_val = f"$$ {new_json} $$" if new_json is not None else "NULL"

    insert_sql = f"""
    INSERT INTO {LOG_TABLE}
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
    session.sql(insert_sql).collect()


# -------------------------
# Helper: parse new_value / old_value into dict
# -------------------------
def parse_new_value(val):
    """Robust parsing for JSON or Python-literal-like values stored in log."""
    if val is None:
        raise ValueError("value is None")
    if isinstance(val, dict):
        return val
    try:
        if isinstance(val, float) and pd.isna(val):
            raise ValueError("value is NaN")
    except Exception:
        pass

    s = str(val).strip()
    m = re.match(r'^\$\$(.*)\$\$$', s, flags=re.DOTALL)
    if m:
        s = m.group(1).strip()

    # Try proper JSON first
    try:
        parsed = json.loads(s)
        if isinstance(parsed, dict):
            return parsed
        else:
            raise ValueError("json parsed not a dict")
    except Exception:
        pass

    # Fix common single-quote/unquoted keys
    s_fixed = re.sub(r'([{\[,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:', r'\1"\2":', s)
    s_fixed = s_fixed.replace("'", '"')
    try:
        parsed = json.loads(s_fixed)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        pass

    # Fallback to ast.literal_eval
    try:
        parsed = ast.literal_eval(s)
        if isinstance(parsed, dict):
            return parsed
        else:
            raise ValueError("literal_eval did not yield dict")
    except Exception as e:
        raise ValueError(f"Could not parse value: {e}; raw={repr(val)}")


# -------------------------
# Helper: fetch main table and sort showing newest on top (if possible)
# -------------------------
def fetch_main_table_sorted(table_name):
    """
    Fetch the main table into a DataFrame.
    Try to bring recently changed records to the top by checking common timestamp-like columns.
    """
    try:
        df = session.table(table_name).to_pandas()
    except Exception as e:
        st.error(f"Could not fetch main table {table_name}: {e}")
        return pd.DataFrame()

    # List of candidate timestamp columns (lowercase)
    ts_candidates = [c for c in df.columns if c.lower() in ("approved_at", "changed_at", "created_at", "updated_at", "load_ts", "changedat", "approvedat")]
    if ts_candidates:
        # prefer the first candidate
        ts_col = ts_candidates[0]
        try:
            # ensure it's datetime & sort descending
            df[ts_col] = pd.to_datetime(df[ts_col], errors="coerce")
            df = df.sort_values(by=ts_col, ascending=False).reset_index(drop=True)
            return df
        except Exception:
            pass

    # fallback: return dataframe as-is
    return df.reset_index(drop=True)


# -------------------------
# Render table UI
# -------------------------
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")

        # show main table (fetch and sort so newest appear on top if possible)
        main_df = fetch_main_table_sorted(main_table)
        if not main_df.empty:
            st.dataframe(main_df)
        else:
            st.info("Main table empty or could not be fetched.")

        key_col = required_cols[-1]

        # ----------------- Upload Section -----------------
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
                            row_dict = {c: clean_for_json(row.get(c)) for c in required_cols_upper}
                            log_change(main_table, "INSERT", None, row_dict)
                            inserted += 1
                        st.success(f"{inserted} rows uploaded to TEMP table and logged.")
                else:
                    st.error(f"Missing columns. Required: {required_cols}")

        # ----------------- Manual Insert -----------------
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

        # ----------------- Update (TEMP) -----------------
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

        # ----------------- Delete (TEMP) -----------------
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


# -------------------------
# Approval Dashboard
# -------------------------
st.markdown("## Approval Dashboard")

# Fetch pending logs
try:
    pending_logs = session.sql(f"SELECT * FROM {LOG_TABLE} WHERE approved = FALSE").to_pandas()
except Exception as e:
    st.error(f"Could not fetch pending logs: {e}")
    pending_logs = pd.DataFrame()

if pending_logs.empty:
    st.success("No pending approvals.")
else:
    st.warning(f"Pending Approvals: {len(pending_logs)} records found.")

    pending_logs.columns = [c.lower() for c in pending_logs.columns]
    display_cols = [c for c in pending_logs.columns if c not in ["log_id", "domain_id", "approved", "approved_by", "approved_at"]]
    display_df = pending_logs[display_cols].copy().reset_index(drop=True)

    if "approve" not in display_df.columns:
        display_df["approve"] = False

    # Render approval editor
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

    # -------------------------
    # Approve Selected Records (final)
    # -------------------------
    if st.button("Approve Selected Records"):
        # Re-fetch authoritative pending logs (we need log_id and original values)
        try:
            pending_logs_db = session.sql(f"SELECT * FROM {LOG_TABLE} WHERE approved = FALSE").to_pandas()
        except Exception as e:
            st.error(f"Could not fetch pending logs for approval: {e}")
            pending_logs_db = pd.DataFrame()

        if pending_logs_db.empty:
            st.info("No pending logs found in DB at approval time.")
        else:
            pending_logs_db.columns = [c.lower() for c in pending_logs_db.columns]

            # Build key map for robust matching: (table_name, action, changed_by, changed_at_iso) -> list of rows
            def row_key_from_db_row(db_row):
                table_name = str(db_row.get("table_name"))
                action = str(db_row.get("action")) if db_row.get("action") is not None else ""
                changed_by = str(db_row.get("changed_by")) if db_row.get("changed_by") is not None else ""
                changed_at = db_row.get("changed_at")
                try:
                    changed_at_iso = changed_at.isoformat() if hasattr(changed_at, "isoformat") else str(changed_at)
                except Exception:
                    changed_at_iso = str(changed_at)
                return (table_name, action, changed_by, changed_at_iso)

            db_key_map = {}
            for _, r in pending_logs_db.iterrows():
                key = row_key_from_db_row(r)
                db_key_map.setdefault(key, []).append(r)

            to_approve = edited_df[edited_df["approve"] == True]
            if to_approve.empty:
                st.warning("No rows selected for approval.")
            else:
                approved_count = 0
                errors = []

                # helper to build SQL literal
                def sql_literal_for_value(v):
                    if v is None:
                        return "NULL"
                    try:
                        if pd.isna(v):
                            return "NULL"
                    except Exception:
                        pass
                    if isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_)):
                        return str(v)
                    s = str(v).strip()
                    if re.fullmatch(r"-?\d+(\.\d+)?", s):
                        return s
                    return "'" + s.replace("'", "''") + "'"

                processed_main_tables = set()  # to inform post-approval UI if needed

                for _, edited_row in to_approve.iterrows():
                    table_name = edited_row.get("table_name")
                    action = edited_row.get("action")
                    changed_by = edited_row.get("changed_by")
                    changed_at = edited_row.get("changed_at")

                    try:
                        changed_at_iso = changed_at.isoformat() if hasattr(changed_at, "isoformat") else str(changed_at)
                    except Exception:
                        changed_at_iso = str(changed_at)

                    lookup_key = (str(table_name), str(action) if action is not None else "", str(changed_by) if changed_by is not None else "", changed_at_iso)
                    matched_db_rows = db_key_map.get(lookup_key)
                    if not matched_db_rows:
                        errors.append(f"No matching DB log found for selected row: {lookup_key}")
                        st.warning(f"No matching DB log found for selected row: {lookup_key}")
                        continue

                    db_row = matched_db_rows.pop(0)
                    log_id = db_row.get("log_id")
                    new_value_db = db_row.get("new_value")
                    old_value_db = db_row.get("old_value")
                    table_name_db = db_row.get("table_name")
                    action_db = db_row.get("action")

                    # find temp mapping
                    temp_table = None
                    for key, info in main_tables.items():
                        if info.get("name") == table_name_db:
                            temp_table = info.get("temp")
                            break

                    if not temp_table:
                        errors.append(f"TEMP table mapping not found for main table {table_name_db} (log_id={log_id})")
                        st.error(f"TEMP table mapping not found for main table {table_name_db} (log_id={log_id})")
                        continue

                    try:
                        # Approve by log_id
                        approve_sql = f"""
                            UPDATE {LOG_TABLE}
                            SET approved = TRUE,
                                approved_by = 'business_user',
                                approved_at = CURRENT_TIMESTAMP
                            WHERE log_id = {log_id} AND approved = FALSE
                        """
                        session.sql(approve_sql).collect()

                        # parse condition dict
                        parsed_condition = None
                        if action_db and str(action_db).upper() == "DELETE":
                            if old_value_db is not None:
                                try:
                                    parsed_condition = parse_new_value(old_value_db)
                                except Exception:
                                    try:
                                        parsed_condition = ast.literal_eval(str(old_value_db))
                                    except Exception:
                                        parsed_condition = None
                        else:
                            if new_value_db is not None:
                                try:
                                    parsed_condition = parse_new_value(new_value_db)
                                except Exception:
                                    try:
                                        parsed_condition = ast.literal_eval(str(new_value_db))
                                    except Exception:
                                        parsed_condition = None

                        # build conditions using uppercase column names
                        conditions = None
                        if isinstance(parsed_condition, dict) and parsed_condition:
                            conds = []
                            for k, v in parsed_condition.items():
                                col_name = str(k).upper()
                                if v is None:
                                    conds.append(f"{col_name} IS NULL")
                                else:
                                    lit = sql_literal_for_value(v)
                                    conds.append(f"{col_name} = {lit}")
                            conditions = " AND ".join(conds)

                        action_upper = str(action_db).upper() if action_db is not None else ""
                        if action_upper in ("INSERT", "UPDATE"):
                            if conditions:
                                insert_sql = f"INSERT INTO {table_name_db} SELECT * FROM {temp_table} WHERE {conditions}"
                                session.sql(insert_sql).collect()
                                session.sql(f"DELETE FROM {temp_table} WHERE {conditions}").collect()
                                approved_count += 1
                                processed_main_tables.add(table_name_db)
                            else:
                                errors.append(f"Could not build conditions for INSERT/UPDATE (log_id={log_id})")
                                st.error(f"Could not build conditions for INSERT/UPDATE (log_id={log_id})")
                                continue

                        elif action_upper == "DELETE":
                            if conditions:
                                session.sql(f"DELETE FROM {temp_table} WHERE {conditions}").collect()
                                approved_count += 1
                                processed_main_tables.add(table_name_db)
                            else:
                                errors.append(f"Could not build delete conditions for log_id={log_id}")
                                st.warning(f"Approved DELETE log but couldn't build delete condition for log_id={log_id}")
                                continue
                        else:
                            # unknown action — approved only
                            approved_count += 1

                    except Exception as e:
                        errors.append(f"Error processing log_id={log_id}: {e}")
                        st.error(f"Error processing log_id={log_id}: {e}")
                        continue

                # end loop over selected rows

                st.success(f"Approval run complete. Successfully applied {approved_count} row(s).")
                if errors:
                    st.warning("Some errors occurred during approval. Check messages above.")

                # Re-run app so the original UI re-fetches pending logs and main tables (no extra tables shown)
                # This rerun will cause the approval dashboard to refresh and the existing main table areas to show latest data.
                st.experimental_rerun()

# -------------------------
# Tabs for Main Tables
# -------------------------
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
