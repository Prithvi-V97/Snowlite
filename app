import json
import pandas as pd
import numpy as np
import streamlit as st
from datetime import datetime
from snowflake.snowpark.context import get_active_session

# --------------------------------------
# Setup
# --------------------------------------
st.title("DDM Dual Table DML Dashboard (Simplified Approval Insert)")
session = get_active_session()

try:
    session.add_packages("openpyxl")
except Exception:
    st.warning("Could not add openpyxl automatically. If Excel upload fails, use CSV instead.")

# --------------------------------------
# Table Mappings
# --------------------------------------
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
        "log": "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG",
        "required_cols": ["SOURCEENTITY", "SOURCEDOMAIN", "TARGETENTITY", "TARGETDOMAIN", "XREFDOMAINVALUE"]
    }
}

LOG_TABLE = "OMNIDDM.COMMON.DDM_DOMAIN_VALUE_LOG"

# --------------------------------------
# Helpers
# --------------------------------------
def normalize_string(s):
    if s is None:
        return None
    if isinstance(s, str):
        return s.replace("\u00A0", " ").strip()
    return s

def read_uploaded_file(uploaded_file):
    try:
        if uploaded_file.name.endswith(".xlsx"):
            df = pd.read_excel(uploaded_file, engine="openpyxl")
        elif uploaded_file.name.endswith(".csv"):
            df = pd.read_csv(uploaded_file)
        else:
            st.error("Unsupported file format.")
            return None
        df = df.applymap(lambda x: normalize_string(x) if isinstance(x, str) else x)
        return df
    except Exception as e:
        st.error(f"Error reading file: {e}")
        return None

def clean_for_json(obj):
    if obj is None:
        return None
    try:
        if pd.isna(obj):
            return None
    except Exception:
        pass
    if isinstance(obj, (np.integer,)):
        return int(obj)
    if isinstance(obj, (np.floating,)):
        return float(obj)
    if isinstance(obj, (np.bool_,)):
        return bool(obj)
    if isinstance(obj, dict):
        return {k: clean_for_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set)):
        return [clean_for_json(v) for v in obj]
    if isinstance(obj, str):
        return normalize_string(obj)
    return obj

def log_change(table_name, action, old_value=None, new_value=None):
    old_json = json.dumps(clean_for_json(old_value)) if old_value else None
    new_json = json.dumps(clean_for_json(new_value)) if new_value else None
    old_val = f"$$ {old_json} $$" if old_json else "NULL"
    new_val = f"$$ {new_json} $$" if new_json else "NULL"
    sql = f"""
        INSERT INTO {LOG_TABLE} (action, table_name, old_value, new_value, changed_by, changed_at, approved)
        VALUES ('{action}', '{table_name}', {old_val}, {new_val}, 'streamlit_user', CURRENT_TIMESTAMP, FALSE)
    """
    session.sql(sql).collect()

def parse_new_value(val):
    try:
        if isinstance(val, dict):
            return val
        if isinstance(val, str):
            s = val.strip()
            if s.startswith("$$") and s.endswith("$$"):
                s = s[2:-2].strip()
            return json.loads(s)
    except Exception:
        return {}
    return {}

# --------------------------------------
# Table UI
# --------------------------------------
def render_table_ui(tab, key):
    info = main_tables[key]
    main_table = info["name"]
    temp_table = info["temp"]
    required_cols = info["required_cols"]

    with tab:
        st.subheader(f"Main Table: {main_table}")
        df = session.table(main_table).to_pandas()
        st.dataframe(df)

        # Upload
        st.markdown("### Upload Excel/CSV to TEMP")
        uploaded = st.file_uploader(f"Upload for {key}", type=["xlsx", "csv"])
        if uploaded:
            df_u = read_uploaded_file(uploaded)
            if df_u is not None:
                df_u.columns = [c.strip().upper() for c in df_u.columns]
                st.dataframe(df_u)
                if all(c in df_u.columns for c in required_cols):
                    if st.button(f"Upload to TEMP for {key}"):
                        for _, r in df_u.iterrows():
                            vals = []
                            for c in required_cols:
                                v = normalize_string(r.get(c))
                                if v in [None, ""]:
                                    vals.append("NULL")
                                else:
                                    vals.append("'" + str(v).replace("'", "''") + "'")
                            sql = f"INSERT INTO {temp_table} ({', '.join(required_cols)}) VALUES ({', '.join(vals)})"
                            session.sql(sql).collect()
                            log_change(main_table, "INSERT", None, r.to_dict())
                        st.success("Uploaded to TEMP and logged.")
                else:
                    st.error("Missing required columns.")

        # Manual Insert
        st.subheader("Manual Insert into TEMP")
        with st.form(f"manual_insert_{key}"):
            inputs = {c: st.text_input(c) for c in required_cols}
            submit = st.form_submit_button("Insert")
            if submit:
                vals = []
                for v in inputs.values():
                    v = normalize_string(v)
                    if v in [None, ""]:
                        vals.append("NULL")
                    else:
                        vals.append("'" + str(v).replace("'", "''") + "'")
                sql = f"INSERT INTO {temp_table} ({', '.join(required_cols)}) VALUES ({', '.join(vals)})"
                session.sql(sql).collect()
                log_change(main_table, "INSERT", None, inputs)
                st.success("Inserted into TEMP and logged.")

# --------------------------------------
# Approval Dashboard
# --------------------------------------
st.markdown("## Approval Dashboard")
try:
    logs = session.sql(f"SELECT * FROM {LOG_TABLE} WHERE approved = FALSE").to_pandas()
except Exception as e:
    st.error(str(e))
    logs = pd.DataFrame()

if logs.empty:
    st.success("No pending approvals.")
else:
    logs.columns = [c.lower() for c in logs.columns]
    display_cols = [c for c in logs.columns if c not in ["approved", "approved_by", "approved_at"]]
    logs["approve"] = False
    edited = st.data_editor(
        logs[display_cols + ["approve"]],
        hide_index=True,
        use_container_width=True,
        height=400,
        column_config={
            "approve": st.column_config.CheckboxColumn("Approve", help="Approve this record")
        }
    )

    if st.button("Approve Selected Records"):
        to_approve = edited[edited["approve"] == True]
        if to_approve.empty:
            st.warning("No records selected.")
        else:
            count = 0
            for _, row in to_approve.iterrows():
                table_name = row["table_name"]
                new_val = parse_new_value(row["new_value"])

                # Find corresponding main table info
                main_table = None
                for k, info in main_tables.items():
                    if info["name"] == table_name:
                        main_table = info
                        break
                if not main_table:
                    st.error(f"No mapping found for {table_name}")
                    continue

                cols = main_table["required_cols"]
                vals = []
                for c in cols:
                    v = normalize_string(new_val.get(c)) if isinstance(new_val, dict) else None
                    if v in [None, ""]:
                        vals.append("NULL")
                    else:
                        vals.append("'" + str(v).replace("'", "''") + "'")

                sql = f"INSERT INTO {table_name} ({', '.join(cols)}) VALUES ({', '.join(vals)})"
                try:
                    session.sql(sql).collect()
                    # mark as approved
                    session.sql(f"UPDATE {LOG_TABLE} SET approved = TRUE, approved_by = 'business_user', approved_at = CURRENT_TIMESTAMP WHERE table_name = '{table_name}' AND changed_at = '{row['changed_at']}'").collect()
                    count += 1
                except Exception as e:
                    st.error(f"Insert failed for {table_name}: {e}")

            st.success(f"Approved and inserted {count} record(s) into main table.")
            st.rerun()

# --------------------------------------
# Tabs
# --------------------------------------
tab1, tab2 = st.tabs(["DDM_DOMAIN_VALUE", "DDM_XREF_DOMAIN_VALUE"])
render_table_ui(tab1, "DDM_DOMAIN_VALUE")
render_table_ui(tab2, "DDM_XREF_DOMAIN_VALUE")
