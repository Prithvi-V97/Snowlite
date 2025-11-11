import ast
import json
import re
import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session
from datetime import datetime

# ----------------------------------------------------------------------
# Streamlit Setup
# ----------------------------------------------------------------------
st.set_page_config(
    page_title="DDM Dual Table DML Dashboard with Approval Workflow",
    layout="wide",
)
st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Enhanced)")

# ----------------------------------------------------------------------
# Get Snowpark session
# ----------------------------------------------------------------------
session = get_active_session()

# Try adding openpyxl for Excel uploads (best-effort)
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# ----------------------------------------------------------------------
# Table Mappings
# ----------------------------------------------------------------------
main_tables = {
    "DDM_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_TEMP",
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["TARGETENTITY", "TARGETDOMAIN", "DOMAINVALUE", "DESCRIPTION"],
    },
    "DDM_XREF_DOMAIN_VALUE": {
        "name": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE",
        "temp": "OMNIDDM.COMMON.DDM_XREF_DOMAIN_VALUE_TEMP",
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",  # Using same log
        "required_cols": [
            "SOURCEENTITY",
            "SOURCEDOMAIN",
            "TARGETENTITY",
            "TARGETDOMAIN",
            "XREFDOMAINVALUE",
        ],
    },
}

# ----------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------
def sanitize_for_log(obj):
    """Sanitize objects for JSON/log storage."""
    if obj is None:
        return None
    if isinstance(obj, dict):
        cleaned = {}
        for k, v in obj.items():
            if isinstance(v, str):
                cleaned[k] = v.replace("\u00a0", " ").strip()
            else:
                if isinstance(v, float) and (v != v):  # NaN check
                    cleaned[k] = None
                else:
                    cleaned[k] = v
        return cleaned
    return obj


def log_change(log_table, table_name, action, old_value=None, new_value=None):
    """Insert a log entry."""
    old_s = sanitize_for_log(old_value)
    new_s = sanitize_for_log(new_value)

    try:
        old_json = json.dumps(old_s) if old_s is not None else None
    except Exception:
        old_json = json.dumps(str(old_s))

    try:
        new_json = json.dumps(new_s) if new_s is not None else None
    except Exception:
        new_json = json.dumps(str(new_s))

    old_val_sql = f"$$ {old_json} $$" if old_json else "NULL"
    new_val_sql = f"$$ {new_json} $$" if new_json else "NULL"

    insert_sql = f"""
        INSERT INTO {log_table} (action, table_name, old_value, new_value, changed_by, changed_at, approved)
        VALUES (
            '{action}',
            '{table_name}',
            {old_val_sql},
            {new_val_sql},
            'streamlit_user',
            CURRENT_TIMESTAMP,
            FALSE
        )
    """

    try:
        session.sql(insert_sql).collect()
    except Exception as e:
        st.error(f"Failed to insert log: {e}")


def parse_new_value(raw):
    """Parse new_value JSON or Python dict from log table."""
    if raw is None:
        raise ValueError("new_value is None")

    if isinstance(raw, dict):
        return {k: v for k, v in raw.items()}

    s = str(raw).strip()
    if s.startswith("$$") and s.endswith("$$"):
        s = s[2:-2].strip()

    s = s.replace("\u00a0", " ").strip()
    s_json_ready = re.sub(r'(?<!")\bNaN\b(?!")', "null", s)

    try:
        parsed = json.loads(s_json_ready)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        pass

    s_py_ready = re.sub(r"\bNaN\b", "None", s)
    try:
        parsed = ast.literal_eval(s_py_ready)
        if isinstance(parsed, dict):
            return parsed
    except Exception as e:
        raise ValueError(f"Failed to parse new_value: {e}")

    raise ValueError("Could not parse new_value")


def read_uploaded_file(uploaded_file):
    """Read Excel or CSV file."""
    try:
        if uploaded_file.name.endswith(".xlsx"):
            return pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            try:
                return pd.read_csv(uploaded_file, encoding="utf-8")
            except UnicodeDecodeError:
                return pd.read_csv(uploaded_file, encoding="ISO-8859-1")
        else:
            st.error("Unsupported file type.")
            return None
    except Exception as e:
        st.error(f"Error reading file: {e}")
        return None

# ----------------------------------------------------------------------
# Table UI
# ----------------------------------------------------------------------
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    log_table = info["log"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")
        try:
            df = session.table(main_table).to_pandas()
            st.dataframe(df, use_container_width=True)
        except Exception as e:
            st.error(f"Could not read main table: {e}")

        key_col = required_cols[-1]

        # ---------------- Upload ----------------
        st.markdown(f"### Upload Excel or CSV for {table_key}")
        uploaded_file = st.file_uploader(f"Upload for {table_key}", type=["xlsx", "csv"], key=f"upload_{table_key}")

        if uploaded_file:
            excel_df = read_uploaded_file(uploaded_file)
            if excel_df is not None:
                excel_df.columns = [col.strip().upper() for col in excel_df.columns]
                st.dataframe(excel_df.head())

                if all(col in excel_df.columns for col in [c.upper() for c in required_cols]):
                    if st.button(f"Upload to TEMP for {table_key}", key=f"btn_upload_{table_key}"):
                        inserted = 0
                        for _, row in excel_df.iterrows():
                            try:
                                cols = ", ".join([c.upper() for c in required_cols])
                                vals_list = []
                                for col in required_cols:
                                    val = row[col.upper()]
                                    if pd.isna(val):
                                        vals_list.append("NULL")
                                    else:
                                        safe_val = str(val).replace("'", "''")
                                        vals_list.append(f"'{safe_val}'")
                                vals = ", ".join(vals_list)

                                insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                                session.sql(insert_sql).collect()

                                row_dict = {col.upper(): None if pd.isna(row[col.upper()]) else str(row[col.upper()]).strip() for col in required_cols}
                                log_change(log_table, main_table, "INSERT", None, row_dict)
                                inserted += 1
                            except Exception as e:
                                st.error(f"Error inserting row: {e}")
                        st.success(f"Uploaded {inserted} rows to TEMP and logged.")
                else:
                    st.error(f"Missing required columns: {required_cols}")

        # ---------------- Manual Insert ----------------
        st.subheader("Manual Insert into TEMP")
        with st.form(f"insert_form_{table_key}"):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                try:
                    cols = ", ".join(inputs.keys())
                    vals = []
                    for v in inputs.values():
                        if v.strip() == "":
                            vals.append("NULL")
                        else:
                            vals.append(f"'{v.replace('\'', '\'\'')}'")
                    val_str = ", ".join(vals)

                    sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({val_str})"
                    session.sql(sql).collect()

                    log_change(log_table, main_table, "INSERT", None, inputs)
                    st.success("Record inserted and logged.")
                except Exception as e:
                    st.error(f"Insert failed: {e}")

        # ---------------- Update ----------------
        st.subheader("Update Record in TEMP")
        with st.form(f"update_form_{table_key}"):
            upd_key = st.text_input(f"{key_col} to update")
            upd_col = st.selectbox("Column to update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit = st.form_submit_button("Update")
            if submit:
                try:
                    old_df = session.sql(
                        f"SELECT {upd_col} FROM {temp_table} WHERE {key_col} = '{upd_key.replace('\'', '\'\'')}'"
                    ).to_pandas()
                    old_val = old_df.iloc[0, 0] if not old_df.empty else None

                    update_sql = (
                        f"UPDATE {temp_table} SET {upd_col} = '{new_value.replace('\'', '\'\'')}' "
                        f"WHERE {key_col} = '{upd_key.replace('\'', '\'\'')}'"
                    )
                    session.sql(update_sql).collect()
                    log_change(log_table, main_table, "UPDATE", {upd_col: old_val}, {upd_col: new_value})
                    st.success("Updated record and logged.")
                except Exception as e:
                    st.error(f"Update failed: {e}")

        # ---------------- Delete ----------------
        st.subheader("Delete Record from TEMP")
        with st.form(f"delete_form_{table_key}"):
            del_key = st.text_input(f"{key_col} to delete")
            confirm = st.checkbox("Confirm delete")
            submit = st.form_submit_button("Delete")
            if submit and confirm:
                try:
                    old_df = session.sql(
                        f"SELECT * FROM {temp_table} WHERE {key_col} = '{del_key.replace('\'', '\'\'')}'"
                    ).to_pandas()
                    old_val = old_df.to_dict(orient="records")[0] if not old_df.empty else None

                    delete_sql = f"DELETE FROM {temp_table} WHERE {key_col} = '{del_key.replace('\'', '\'\'')}'"
                    session.sql(delete_sql).collect()
                    log_change(log_table, main_table, "DELETE", old_val, None)
                    st.success("Deleted record and logged.")
                except Exception as e:
                    st.error(f"Delete failed: {e}")
            elif submit:
                st.warning("Please confirm deletion before proceeding.")

# ----------------------------------------------------------------------
# Approval Dashboard
# ----------------------------------------------------------------------
st.markdown("## Approval Dashboard")

log_tables = sorted({info["log"] for info in main_tables.values()})
pending_logs = []

for lt in log_tables:
    try:
        df = session.sql(f"SELECT *, '{lt}' AS log_table_source FROM {lt} WHERE approved = FALSE").to_pandas()
        if not df.empty:
            pending_logs.append(df)
    except Exception:
        st.warning(f"Could not read log table: {lt}")

if not pending_logs:
    st.success("No pending approvals.")
else:
    pending_df = pd.concat(pending_logs, ignore_index=True)
    st.warning(f"{len(pending_df)} pending approvals found.")
    pending_df.columns = [c.lower() for c in pending_df.columns]

    display_cols = [
        c for c in pending_df.columns if c not in ["log_id", "approved", "approved_by", "approved_at"]
    ]
    display_df = pending_df[display_cols].copy()
    display_df["approve"] = False

    edited = st.data_editor(
        display_df,
        use_container_width=True,
        column_config={"approve": st.column_config.CheckboxColumn("Approve", help="Select to approve")},
    )

    if st.button("Approve Selected Records"):
        to_approve = edited[edited["approve"]]
        if to_approve.empty:
            st.warning("No records selected.")
        else:
            approved_count = 0
            for _, row in to_approve.iterrows():
                try:
                    log_table = row["log_table_source"]
                    table_name = row["table_name"]
                    new_value = row["new_value"]
                    changed_by = str(row["changed_by"])
                    action = row["action"]

                    approve_sql = f"""
                        UPDATE {log_table}
                        SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP
                        WHERE table_name = '{table_name.replace("'", "''")}'
                          AND action = '{action.replace("'", "''")}'
                          AND changed_by = '{changed_by.replace("'", "''")}'
                          AND approved = FALSE
                    """
                    session.sql(approve_sql).collect()

                    if new_value:
                        new_val_dict = parse_new_value(new_value)
                        conds = []
                        for k, v in new_val_dict.items():
                            if v is None:
                                conds.append(f"{k} IS NULL")
                            else:
                                conds.append(f"{k} = '{str(v).replace("'", "''")}'")
                        where_clause = " AND ".join(conds) if conds else "1=1"

                        temp_table = next((info["temp"] for info in main_tables.values() if info["name"] == table_name), None)
                        if temp_table:
                            insert_sql = f"INSERT INTO {table_name} SELECT * FROM {temp_table} WHERE {where_clause}"
                            delete_sql = f"DELETE FROM {temp_table} WHERE {where_clause}"
                            session.sql(insert_sql).collect()
                            session.sql(delete_sql).collect()
                            approved_count += 1
                except Exception as e:
                    st.error(f"Approval failed: {e}")

            st.success(f"Approved and applied {approved_count} records.")

# ----------------------------------------------------------------------
# Tabs for main tables
# ----------------------------------------------------------------------
tab1, tab2 = st.tabs(list(main_tables.keys()))
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
