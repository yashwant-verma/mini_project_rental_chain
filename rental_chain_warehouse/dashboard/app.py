"""Sakila Rental Chain Performance | Streamlit dashboard.

Run after SQL schema + ETL:
    pip install -r requirements.txt
    streamlit run dashboard/app.py
Database credentials come from environment variables, not source code.
"""

from __future__ import annotations

import os
from datetime import date
from urllib.parse import quote_plus

import pandas as pd
import plotly.express as px
import streamlit as st
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

st.set_page_config(
    page_title="Rental Chain | Store Performance",
    page_icon="🎬",
    layout="wide",
)

st.title("🎬 Rental Chain Performance Warehouse")
st.caption("Sakila · Rental-attributed revenue · Store comparison · Category loyalty · Inventory utilization")


@st.cache_resource
def database_engine():
    host = os.getenv("MYSQL_HOST", "127.0.0.1")
    port = os.getenv("MYSQL_PORT", "3306")
    user = os.getenv("MYSQL_USER", "root")
    password = quote_plus(os.getenv("MYSQL_PASSWORD", ""))
    database = os.getenv("MYSQL_DATABASE", "sakila_dw")
    # Using quote_plus keeps special characters in passwords from breaking the URL.
    return create_engine(
        f"mysql+pymysql://{quote_plus(user)}:{password}@{host}:{port}/{database}",
        pool_pre_ping=True,
    )


def read_query(query: str, **params) -> pd.DataFrame:
    with database_engine().connect() as connection:
        return pd.read_sql_query(text(query), connection, params=params)


@st.cache_data(ttl=120)
def rental_date_bounds() -> tuple[date, date]:
    dates = read_query(
        """SELECT MIN(DATE(rental_date)) AS first_date,
                  MAX(DATE(rental_date)) AS last_date
           FROM fact_rental"""
    )
    if dates.empty or pd.isna(dates.at[0, "first_date"]):
        raise ValueError("No data in fact_rental. Run the ETL SQL script first.")
    first = pd.to_datetime(dates.at[0, "first_date"]).date()
    last = pd.to_datetime(dates.at[0, "last_date"]).date()
    return first, last


@st.cache_data(ttl=120)
def load_scorecards(start_key: int, end_key: int):
    params = {"start_key": start_key, "end_key": end_key}

    # LEFT JOIN: show stores even if they had zero rentals in the selected period.
    stores = read_query(
        """
        SELECT s.store_key, s.store_name, a.city, a.country,
               COALESCE(SUM(m.rentals),0) AS rentals,
               COALESCE(SUM(m.revenue),0) AS revenue,
               COALESCE(SUM(m.returned_rentals),0) AS returned_rentals,
               COALESCE(SUM(m.late_returns),0) AS late_returns,
               COALESCE(100.0 * SUM(m.late_returns)
                        / NULLIF(SUM(m.returned_rentals),0),0) AS late_pct
        FROM dim_store s
        JOIN dim_address a ON a.address_id=s.address_id
        LEFT JOIN mart_store_day m
          ON m.store_key=s.store_key
         AND m.rental_date_key BETWEEN :start_key AND :end_key
        GROUP BY s.store_key, s.store_name, a.city, a.country
        ORDER BY s.store_key
        """,
        **params,
    )

    categories = read_query(
        """
        SELECT s.store_key, s.store_name, c.category_name,
               SUM(m.allocated_revenue) AS category_revenue,
               SUM(m.allocated_rentals) AS allocated_rentals,
               SUM(m.allocated_late_returns) AS allocated_late_returns,
               SUM(m.allocated_returns) AS allocated_returns
        FROM mart_store_category_day m
        JOIN dim_store s ON s.store_key=m.store_key
        JOIN dim_category c ON c.category_key=m.category_key
        WHERE m.rental_date_key BETWEEN :start_key AND :end_key
        GROUP BY s.store_key, s.store_name, c.category_key, c.category_name
        ORDER BY s.store_key, category_revenue DESC
        """,
        **params,
    )

    # A copy is "active" if it was rented at least once within the filter window.
    # This is an event-based utilization proxy, not physical occupancy %.
    utilization = read_query(
        """
        SELECT s.store_key, s.store_name,
               COUNT(i.inventory_id) AS total_copies,
               SUM(CASE WHEN COALESCE(x.events,0) > 0 THEN 1 ELSE 0 END) AS active_copies,
               SUM(CASE WHEN i.inventory_id IS NOT NULL AND COALESCE(x.events,0)=0
                        THEN 1 ELSE 0 END) AS idle_copies,
               COALESCE(SUM(x.events),0) AS rental_events,
               COALESCE(100.0 * SUM(CASE WHEN COALESCE(x.events,0)>0
                                         THEN 1 ELSE 0 END)
                        / NULLIF(COUNT(i.inventory_id),0),0) AS active_copy_pct,
               COALESCE(SUM(x.events)/NULLIF(COUNT(i.inventory_id),0),0) AS rentals_per_copy
        FROM dim_store s
        LEFT JOIN dim_inventory i ON i.store_key=s.store_key
        LEFT JOIN (
          SELECT inventory_id, COUNT(*) AS events
          FROM fact_rental
          WHERE rental_date_key BETWEEN :start_key AND :end_key
          GROUP BY inventory_id
        ) x ON x.inventory_id=i.inventory_id
        GROUP BY s.store_key, s.store_name
        ORDER BY s.store_key
        """,
        **params,
    )

    loyalty = read_query(
        """
        SELECT s.store_key, s.store_name, c.category_name,
               COUNT(*) AS unique_customers,
               SUM(CASE WHEN y.times_rented >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
               100.0 * SUM(CASE WHEN y.times_rented >= 2 THEN 1 ELSE 0 END)
                        / NULLIF(COUNT(*),0) AS repeat_pct
        FROM (
          SELECT fr.store_key, bc.category_key, fr.customer_key,
                 COUNT(*) AS times_rented
          FROM fact_rental fr
          JOIN bridge_film_category bc ON bc.film_key=fr.film_key
          WHERE fr.rental_date_key BETWEEN :start_key AND :end_key
          GROUP BY fr.store_key, bc.category_key, fr.customer_key
        ) y
        JOIN dim_store s ON s.store_key=y.store_key
        JOIN dim_category c ON c.category_key=y.category_key
        GROUP BY s.store_key, s.store_name, c.category_key, c.category_name
        ORDER BY repeat_pct DESC
        """,
        **params,
    )

    # All individual copies: allows filtering to zero-use inventory after store selection.
    copies = read_query(
        """
        SELECT s.store_key, s.store_name, i.inventory_id, f.title AS film_title,
               COUNT(fr.rental_id) AS rental_events
        FROM dim_inventory i
        JOIN dim_store s ON s.store_key=i.store_key
        JOIN dim_film f ON f.film_key=i.film_key
        LEFT JOIN fact_rental fr
          ON fr.inventory_id=i.inventory_id
         AND fr.rental_date_key BETWEEN :start_key AND :end_key
        GROUP BY s.store_key, s.store_name, i.inventory_id, f.title
        ORDER BY rental_events, s.store_key, i.inventory_id
        """,
        **params,
    )
    return stores, categories, utilization, loyalty, copies


def ensure_numbers(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    frame = df.copy()
    for column in columns:
        if column in frame.columns:
            frame[column] = pd.to_numeric(frame[column], errors="coerce").fillna(0)
    if "store_key" in frame.columns:
        frame["store_key"] = pd.to_numeric(frame["store_key"], errors="coerce").astype(int)
    return frame


try:
    min_date, max_date = rental_date_bounds()
except (SQLAlchemyError, ValueError, OSError) as exc:
    st.error("Database unavailable or empty. Install Sakila and run 01_schema.sql, then 02_etl.sql.")
    st.code(str(exc))
    st.stop()

st.sidebar.header("Filters")
st.sidebar.caption("Defaults to the full date range in the sample data.")
start_date = st.sidebar.date_input("Rental date from", value=min_date, min_value=min_date, max_value=max_date)
end_date = st.sidebar.date_input("Rental date through", value=max_date, min_value=min_date, max_value=max_date)
if start_date > end_date:
    st.warning("Start date must not be later than end date.")
    st.stop()

start_key = int(start_date.strftime("%Y%m%d"))
end_key = int(end_date.strftime("%Y%m%d"))
try:
    stores, categories, utilization, loyalty, copies = load_scorecards(start_key, end_key)
except (SQLAlchemyError, OSError) as exc:
    st.error("Unable to read the warehouse marts. Check the connection and run ETL.")
    st.code(str(exc))
    st.stop()

stores = ensure_numbers(stores, ["rentals", "revenue", "returned_rentals", "late_returns", "late_pct"])
categories = ensure_numbers(categories, ["category_revenue", "allocated_rentals", "allocated_late_returns", "allocated_returns"])
utilization = ensure_numbers(utilization, ["total_copies", "active_copies", "idle_copies", "rental_events", "active_copy_pct", "rentals_per_copy"])
loyalty = ensure_numbers(loyalty, ["unique_customers", "repeat_customers", "repeat_pct"])
copies = ensure_numbers(copies, ["rental_events"])

selected_stores = st.sidebar.multiselect(
    "Stores",
    options=stores["store_key"].tolist(),
    default=stores["store_key"].tolist(),
    format_func=lambda key: stores.loc[stores.store_key == key, "store_name"].iloc[0],
)
if not selected_stores:
    st.info("Choose at least one store from the sidebar.")
    st.stop()

sview = stores[stores.store_key.isin(selected_stores)].copy()
cview = categories[categories.store_key.isin(selected_stores)].copy()
uview = utilization[utilization.store_key.isin(selected_stores)].copy()
lview = loyalty[loyalty.store_key.isin(selected_stores)].copy()
iview = copies[copies.store_key.isin(selected_stores)].copy()

rental_sum = int(sview.rentals.sum())
revenue_sum = float(sview.revenue.sum())
returns_sum = int(sview.returned_rentals.sum())
late_sum = int(sview.late_returns.sum())
active_copies = int(uview.active_copies.sum())
total_copies = int(uview.total_copies.sum())
late_pct = 100 * late_sum / returns_sum if returns_sum else 0
util_pct = 100 * active_copies / total_copies if total_copies else 0

k1, k2, k3, k4 = st.columns(4)
k1.metric("Revenue (rental-attributed)", f"{revenue_sum:,.2f}")
k2.metric("Rentals", f"{rental_sum:,}")
k3.metric("Late returns / returned", f"{late_pct:.1f}%")
k4.metric("Active inventory copies", f"{util_pct:.1f}%")

st.divider()
st.subheader("1 · Store comparison")
left, right = st.columns(2)
with left:
    st.plotly_chart(
        px.bar(sview, x="store_name", y="revenue", text_auto=".2f",
               labels={"store_name": "Store", "revenue": "Revenue"},
               title="Revenue by store"),
        use_container_width=True,
    )
with right:
    st.plotly_chart(
        px.bar(sview, x="store_name", y="late_pct", text_auto=".1f",
               labels={"store_name": "Store", "late_pct": "Late returns (%)"},
               title="Late-return rate by store"),
        use_container_width=True,
    )
st.dataframe(
    sview[["store_name", "city", "country", "rentals", "revenue", "returned_rentals", "late_returns", "late_pct"]].round(2),
    hide_index=True, use_container_width=True,
)

st.divider()
st.subheader("2 · Category revenue and repeat customers")
left, right = st.columns(2)
with left:
    if not cview.empty:
        st.plotly_chart(
            px.bar(cview, x="category_name", y="category_revenue", color="store_name",
                   barmode="group", title="Revenue by category and store",
                   labels={"category_name": "Category", "category_revenue": "Allocated revenue", "store_name": "Store"}),
            use_container_width=True,
        )
    else:
        st.info("No category rentals in this date range.")
with right:
    if not lview.empty:
        st.plotly_chart(
            px.bar(lview, x="category_name", y="repeat_pct", color="store_name",
                   barmode="group", title="Repeat-customer rate by category",
                   labels={"category_name": "Category", "repeat_pct": "Repeat customers (%)", "store_name": "Store"}),
            use_container_width=True,
        )
    else:
        st.info("No repeat customer records in this date range.")
with st.expander("Repeat customer details"):
    st.dataframe(
        lview[["store_name", "category_name", "unique_customers", "repeat_customers", "repeat_pct"]].round(2),
        hide_index=True, use_container_width=True,
    )

st.divider()
st.subheader("3 · Inventory utilization scorecard")
st.dataframe(
    uview[["store_name", "total_copies", "active_copies", "idle_copies", "rental_events", "active_copy_pct", "rentals_per_copy"]].round(2),
    hide_index=True, use_container_width=True,
)
left, right = st.columns(2)
with left:
    st.plotly_chart(
        px.bar(uview, x="store_name", y=["active_copies", "idle_copies"],
               barmode="stack", title="Active vs idle inventory copies",
               labels={"store_name": "Store", "value": "Inventory copies", "variable": "Status"}),
        use_container_width=True,
    )
with right:
    st.plotly_chart(
        px.bar(uview, x="store_name", y="rentals_per_copy", text_auto=".2f",
               title="Rental events per copy",
               labels={"store_name": "Store", "rentals_per_copy": "Rentals per inventory copy"}),
        use_container_width=True,
    )

st.subheader("Under-used inventory")
zero_use_only = st.checkbox("Show only copies with zero rentals in this period", value=True)
if zero_use_only:
    iview = iview[iview.rental_events == 0]
if iview.empty:
    st.success("No inventory copies match this filter.")
else:
    st.dataframe(
        iview[["store_name", "inventory_id", "film_title", "rental_events"]].sort_values(
            ["rental_events", "store_name", "inventory_id"]
        ).head(100),
        hide_index=True, use_container_width=True,
    )
    st.caption(f"Displaying up to 100 of {len(iview):,} matching inventory copies.")

with st.expander("Metric definitions and caveats"):
    st.markdown(
        """
        - **Revenue** is summed from all payments linked to a rental, attributed to that rental's date; payments without a rental link are excluded.
        - **Late-return %** = returned rentals with `return_date > rental_date + film.allowed_rental_days`, divided by returned rentals. Unreturned rentals are not counted as returned or late.
        - **Active copy %** = distinct inventory copies rented at least once during the selected dates / all currently listed copies in a store.
        - **Rentals per copy** = rental transactions / number of inventory copies in store; this is not occupancy, shelf time, or a weighted stock turnover rate.
        - **Repeat customer %** = customers with 2+ rentals in the same category and store within the chosen dates / unique customers in that store/category.
        - **Category revenue** is split proportionally for films linked to multiple categories, preventing double-counting.
        - Inventory is a **current snapshot**, not a historically versioned inventory ledger. Historical utilization therefore assumes no material stock changes.
        - Standard Sakila data is historical; filters automatically use the sample's rental dates, not the current year.
        """
    )
