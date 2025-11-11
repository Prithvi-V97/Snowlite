import streamlit as st
import pandas as pd
import json
from snowflake.snowpark.context import get_active_session
from datetime import datetime

st.title("DDM Dual Table DML Dashboard with Approval Workflow (TEMP + LOG Enhanced)")

# Snowflake session
session = get_active_session()

# Try to add openpyxl for Excel uploads
try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# =====================================================
# Table Mappings (Main, Temp, and Log)
# =====================================================
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
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",  # using same log structure
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

# =====================================================
# Helper - Read Uploaded File
# =====================================================
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

# =====================================================
# Helper - Log Change
# =====================================================
def log_change(table_name, action, old_value=None, new_value=None):
    old_json = json.dumps(old_value) if old_value is not None else None
    new_json = json.dumps(new_value) if new_value is not None else None

    log_sql = f"""
    INSERT INTO OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG 
        (action, table_name, old_value, new_value, changed_by, changed_at, approved)
    VALUES 
        (
            '{action}', 
            '{table_name}', 
            {f"$$ {old_json} $$" if old_json else 'NULL'}, 
            {f"$$ {new_json} $$" if new_json else 'NULL'}, 
            'streamlit_user', 
            CURRENT_TIMESTAMP, 
            FALSE
        )
    """
    session.sql(log_sql).collect()

# =====================================================
# Render Table UI
# =====================================================
def render_table_ui(tab, table_key):
    info = main_tables[table_key]
    main_table = info["name"]
    temp_table = info["temp"]
    log_table = info["log"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")
        df = session.table(main_table).to_pandas()
        st.dataframe(df)
        key_col = required_cols[-1]

        # =====================================================
        # Upload Section
        # =====================================================
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
                        for _, row in excel_df.iterrows():
                            cols = ", ".join(required_cols_upper)
                            vals = ", ".join([f"'{row[col]}'" for col in required_cols_upper])
                            insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                            session.sql(insert_sql).collect()
                            log_change(main_table, "INSERT", None, row[required_cols_upper].to_dict())
                        st.success("Data uploaded to TEMP table and logged.")
                else:
                    st.error(f"Missing columns. Required: {required_cols}")

        # =====================================================
        # Manual Insert
        # =====================================================
        st.subheader("Manual Insert into TEMP Table")
        with st.form(f"insert_form{table_key}"):
            inputs = {col: st.text_input(col) for col in required_cols}
            submit = st.form_submit_button("Insert Record")
            if submit:
                cols = ", ".join(inputs.keys())
                vals = ", ".join([f"'{v}'" for v in inputs.values()])
                insert_sql = f"INSERT INTO {temp_table} ({cols}) VALUES ({vals})"
                session.sql(insert_sql).collect()
                log_change(main_table, "INSERT", None, inputs)
                st.success("Record inserted into TEMP and logged.")

        # =====================================================
        # Update Record (TEMP)
        # =====================================================
        st.subheader("Update Record (in TEMP Table)")
        with st.form(f"update_form_{table_key}"):
            upd_key = st.text_input(f"{key_col} to Update")
            upd_col = st.selectbox("Column to Update", [c for c in required_cols if c != key_col])
            new_value = st.text_input("New Value")
            submit_upd = st.form_submit_button("Update Record")
            if submit_upd:
                old_val_df = session.sql(f"SELECT {upd_col} FROM {temp_table} WHERE {key_col} = '{upd_key}'").to_pandas()
                old_val = old_val_df.iloc[0, 0] if not old_val_df.empty else None
                update_sql = f"UPDATE {temp_table} SET {upd_col} = '{new_value}' WHERE {key_col} = '{upd_key}'"
                session.sql(update_sql).collect()
                log_change(main_table, "UPDATE", {upd_col: old_val}, {upd_col: new_value})
                st.success("Record updated in TEMP and logged.")

        # =====================================================
        # Delete Record (TEMP)
        # =====================================================
        st.subheader("Delete Record (from TEMP Table)")
        with st.form(f"delete_form_{table_key}"):
            del_key = st.text_input(f"{key_col} to Delete")
            confirm = st.checkbox("Confirm Delete")
            submit_del = st.form_submit_button("Delete Record")
            if submit_del and confirm:
                old_val_df = session.sql(f"SELECT * FROM {temp_table} WHERE {key_col} = '{del_key}'").to_pandas()
                old_val = old_val_df.to_dict(orient="records")[0] if not old_val_df.empty else None
                delete_sql = f"DELETE FROM {temp_table} WHERE {key_col} = '{del_key}'"
                session.sql(delete_sql).collect()
                log_change(main_table, "DELETE", old_val, None)
                st.success("Record deleted from TEMP and logged.")
            elif submit_del:
                st.warning("Please confirm delete before proceeding.")

# =====================================================
# Approval Dashboard
# =====================================================
st.markdown("## Approval Dashboard")
log_table = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"
pending_logs = session.sql(f"SELECT * FROM {log_table} WHERE approved = FALSE").to_pandas()
if pending_logs.empty:
    st.success("No pending approvals.")
else:
    st.warning(f" Pending Approvals: {len(pending_logs)} records found.")
    st.dataframe(pending_logs)

if st.button("Approve ALL Pending Changes"):
    # Approve logs
    approve_sql = f"""
    UPDATE {log_table} 
    SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP 
    WHERE approved = FALSE
    """
    session.sql(approve_sql).collect()

    # Move TEMP → MAIN
    for key, info in main_tables.items():
        temp_table = info["temp"]
        main_table = info["name"]
        temp_df = session.sql(f"SELECT * FROM {temp_table}").to_pandas()
        if not temp_df.empty:
            insert_sql = f"INSERT INTO {main_table} SELECT * FROM {temp_table}"
            session.sql(insert_sql).collect()
            session.sql(f"TRUNCATE TABLE {temp_table}").collect()
            st.success(f"Moved {len(temp_df)} records from {temp_table} → {main_table}")

    st.success("All pending changes approved and applied successfully!")

# =====================================================
# Tabs for Main Tables
# =====================================================
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
