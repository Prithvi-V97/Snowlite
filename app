# streamlit_app.py
import re
import json
import ast
import numpy as np
import pandas as pd
import streamlit as st
from datetime import datetime, date
from snowflake.snowpark.context import get_active_session

# =====================================================
# App Title and Snowflake Session
# =====================================================
st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Simplified)")

session = get_active_session()

# Try adding openpyxl for Excel uploads
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# =====================================================
# Table Mappings
# =====================================================
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
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"],
    },
}

LOG_TABLE = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"

# =====================================================
# Helper Functions
# =====================================================
def normalize_string(s):
    """Replace non-breaking spaces with normal spaces and trim."""
    if s is None:
        return None
    if isinstance(s, str):
        return s.replace("\u00A0", " ").strip()
    return s


def read_uploaded_file(uploaded_file):
    """Read Excel or CSV and normalize all strings."""
    try:
        if uploaded_file.name.endswith(".xlsx"):
            df = pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            try:
                df = pd.read_csv(uploaded_file, encoding="utf-8")
            except UnicodeDecodeError:
                st.warning("File is not UTF-8 encoded. Trying ISO-8859-1...")
                df = pd.read_csv(uploaded_file, encoding="ISO-8859-1")
        else:
            st.error("Unsupported file format. Please upload .xlsx or .csv")
            return None
        df = df.applymap(lambda x: normalize_string(x) if isinstance(x, str) else x)
        return df
    except Exception as e:
        st.error(f"Error reading file: {e}")
        return None


def clean_for_json(obj):
    """Convert values into JSON-safe serializable form."""
    if obj is None:
        return None
    try:
        if pd.isna(obj):
            return None
    except Exception:
        pass
    if isinstance(obj, (pd.Timestamp, datetime)):
        return obj.isoformat()
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
    """Insert a log record into LOG table."""
    cleaned_old = clean_for_json(old_value)
    cleaned_new = clean_for_json(new_value)
    old_json = json.dumps(cleaned_old) if cleaned_old is not None else None
    new_json = json.dumps(cleaned_new) if cleaned_new is not None else None

    old_sql = "$$ " + old_json + " $$" if old_json else "NULL"
    new_sql = "$$ " + new_json + " $$" if new_json else "NULL"

    sql = (
        "INSERT INTO " + LOG_TABLE + " (action, table_name, old_value, new_value, changed_by, changed_at, approved) "
        "VALUES ('" + action + "', '" + table_name + "', "
        + old_sql + ", " + new_sql + ", 'streamlit_user', CURRENT_TIMESTAMP, FALSE)"
    )
    session.sql(sql).collect()


def fetch_main_table_sorted(table_name):
    """Fetch main table and show latest on top if possible."""
    try:
        df = session.table(table_name).to_pandas()
        if "changed_at" in df.columns:
            df["changed_at"] = pd.to_datetime(df["changed_at"], errors="coerce")
            df = df.sort_values("changed_at", ascending=False)
        return df.reset_index(drop=True)
    except Exception:
        return pd.DataFrame()


# =====================================================
# Render Table UI
# =====================================================
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader("Main Table: " + main_table)
        df_main = fetch_main_table_sorted(main_table)
        if not df_main.empty:
            st.dataframe(df_main)
        else:
            st.info("Main table is empty or cannot be fetched.")

        key_col = required_cols[-1]

        # ---------- Upload Section ----------
        st.markdown("### Upload Excel or CSV (Insert into TEMP Table)")
        uploaded_file = st.file_uploader("Upload for " + table_key, type=["xlsx", "csv"])
        if uploaded_file:
            excel_df = read_uploaded_file(uploaded_file)
            if excel_df is not None:
                excel_df.columns = [c.strip().upper() for c in excel_df.columns]
                st.dataframe(excel_df.head())

                if all(col in excel_df.columns for col in required_cols):
                    if st.button("Upload to TEMP for " + table_key):
                        for _, row in excel_df.iterrows():
                            cols = ", ".join(required_cols)
                            vals_list = []
                            for col in required_cols:
                                v = row.get(col, "")
                                v = normalize_string(v)
                                if v in [None, "", np.nan]:
                                    vals_list.append("NULL")
                                else:
                                    vals_list.append("'" + str(v).replace("'", "''") + "'")
                            vals = ", ".join(vals_list)
                            sql = "INSERT INTO " + temp_table + " (" + cols + ") VALUES (" + vals + ")"
                            session.sql(sql).collect()
                            log_change(main_table, "INSERT", None, row.to_dict())
                        st.success("Data uploaded to TEMP and logged.")
                else:
                    st.error("Missing columns. Required: " + str(required_cols))

        # ---------- Manual Insert ----------
        st.subheader("Manual Insert into TEMP Table")
        with st.form("manual_insert_" + table_key):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                cols = ", ".join(inputs.keys())
                vals = []
                for v in inputs.values():
                    v = normalize_string(v)
                    if not v:
                        vals.append("NULL")
                    else:
                        vals.append("'" + str(v).replace("'", "''") + "'")
                sql = "INSERT INTO " + temp_table + " (" + cols + ") VALUES (" + ", ".join(vals) + ")"
                session.sql(sql).collect()
                log_change(main_table, "INSERT", None, inputs)
                st.success("Record inserted into TEMP and logged.")

        # ---------- Update Record ----------
        st.subheader("Update Record in TEMP Table")
        with st.form("update_" + table_key):
            upd_key = st.text_input(key_col + " to Update")
            upd_col = st.selectbox("Column to Update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit_upd = st.form_submit_button("Update Record")
            if submit_upd:
                upd_key = normalize_string(upd_key)
                new_value = normalize_string(new_value)
                escaped_key = str(upd_key).replace("'", "''")
                escaped_val = str(new_value).replace("'", "''")
                sql = (
                    "UPDATE " + temp_table +
                    " SET " + upd_col + " = '" + escaped_val + "' WHERE " + key_col + " = '" + escaped_key + "'"
                )
                session.sql(sql).collect()
                log_change(main_table, "UPDATE", {upd_col: None}, {upd_col: new_value})
                st.success("Record updated in TEMP and logged.")

        # ---------- Delete Record ----------
        st.subheader("Delete Record from TEMP Table")
        with st.form("delete_" + table_key):
            del_key = st.text_input(key_col + " to Delete")
            confirm = st.checkbox("Confirm Delete")
            submit_del = st.form_submit_button("Delete Record")
            if submit_del and confirm:
                del_key = normalize_string(del_key)
                escaped_key = str(del_key).replace("'", "''")
                sql = "DELETE FROM " + temp_table + " WHERE " + key_col + " = '" + escaped_key + "'"
                session.sql(sql).collect()
                log_change(main_table, "DELETE", {key_col: del_key}, None)
                st.success("Record deleted from TEMP and logged.")
            elif submit_del:
                st.warning("Please confirm delete before proceeding.")


# =====================================================
# Approval Dashboard
# =====================================================
st.markdown("## Approval Dashboard")

try:
    pending_logs = session.sql("SELECT * FROM " + LOG_TABLE + " WHERE approved = FALSE").to_pandas()
except Exception as e:
    st.error("Could not fetch pending logs: " + str(e))
    pending_logs = pd.DataFrame()

if pending_logs.empty:
    st.success("No pending approvals.")
else:
    st.warning("Pending Approvals: " + str(len(pending_logs)) + " records found.")

    pending_logs.columns = [c.lower() for c in pending_logs.columns]
    display_cols = [c for c in pending_logs.columns if c not in ["log_id", "approved", "approved_by", "approved_at"]]
    display_df = pending_logs[display_cols].copy().reset_index(drop=True)
    display_df["approve"] = False

    edited_df = st.data_editor(
        display_df,
        use_container_width=True,
        height=400,
        column_config={
            "approve": st.column_config.CheckboxColumn(
                "Approve", help="Tick to approve this record", width=80
            )
        },
        hide_index=True,
    )

    # ---------- Approve Selected ----------
    if st.button("Approve Selected Records"):
        to_approve = edited_df[edited_df["approve"] == True]
        if to_approve.empty:
            st.warning("No rows selected for approval.")
        else:
            approved_count = 0
            for _, row in to_approve.iterrows():
                table_name = row["table_name"]
                temp_table = None
                for key, info in main_tables.items():
                    if info["name"] == table_name:
                        temp_table = info["temp"]
                        break
                if not temp_table:
                    st.error("TEMP table not found for " + table_name)
                    continue

                try:
                    # Insert everything currently in TEMP into MAIN (1 approval = 1 full insert)
                    insert_sql = "INSERT INTO " + table_name + " SELECT * FROM " + temp_table
                    session.sql(insert_sql).collect()

                    # Empty TEMP after insert
                    session.sql("DELETE FROM " + temp_table).collect()

                    # Mark as approved
                    log_id = row.get("log_id")
                    session.sql(
                        "UPDATE " + LOG_TABLE +
                        " SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP "
                        "WHERE log_id = " + str(log_id)
                    ).collect()

                    approved_count += 1

                except Exception as e:
                    st.error("Error approving record: " + str(e))
                    continue

            st.success("Approved " + str(approved_count) + " record(s).")

            # ---------- Refresh UI ----------
            try:
                if hasattr(st, "experimental_rerun"):
                    st.experimental_rerun()
                elif hasattr(st, "rerun"):
                    st.rerun()
                else:
                    import streamlit.components.v1 as components
                    components.html("<script>window.location.reload()</script>", height=0)
            except Exception:
                import streamlit.components.v1 as components
                components.html("<script>window.location.reload()</script>", height=0)

# =====================================================
# Tabs for Main Tables
# =====================================================
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
