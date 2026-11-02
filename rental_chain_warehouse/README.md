# Project 8 — Rental Chain Performance Warehouse

**Industry:** Rental / Entertainment Retail  
**Source:** MySQL Sakila sample database (`film`, `inventory`, `rental`, `payment`, `store`, `customer`, and related lookups)  
**Suggested classroom duration:** 2 hours  
**Deliverables:** Star-schema diagram, staging + warehouse DDL, ETL script, validation queries, interactive store-comparison dashboard, and inventory utilization scorecard.

## 1. Business questions

1. Which store makes more rental-attributed revenue and processes more rentals?
2. Which store has the greatest late-return percentage?
3. Which film categories bring repeat customers to each store?
4. How many inventory copies are idle versus rented at least once in a chosen period?
5. Which individual copies have received the fewest rentals?

## 2. OLTP vs OLAP vs lake — Step 1

| Technology | Purpose in this business | Example |
| --- | --- | --- |
| **OLTP** | Fast atomic transactions used by rental-counter staff | Insert rental, accept payment, process return, update inventory |
| **OLAP** | Analyze historical patterns across stores, categories, customers and dates | Revenue by store and category; late returns; repeated category rentals |
| **Warehouse** | Clean, validated, structured, governed reporting data; SQL aggregates and recurring dashboards | `fact_rental`, dimensions and `mart_store_day` |
| **Data lake** | Store raw, large or semi-structured records with flexible schema, often before transformation | Web clickstream JSON, app logs, browsing events and raw streaming files |

**When choose a lake?** If the chain starts collecting high-volume clickstream or app logs with changing JSON attributes, keep the raw records in an economical lake for exploratory and schema-on-read use; curate useful summaries into the warehouse for trusted reporting. A lake and a warehouse can coexist.

**Schema-on-write:** In this warehouse, structured types and columns are validated at load time. **Schema-on-read:** In a raw JSON lake, parsing/typing may occur when analysts query the records.

## 3. Source entities and relationships — Step 3

- `store` has many `inventory` copies; each copy refers to one `film`.
- `customer` has many `rental` events; each `rental` refers to one `inventory` copy and one customer.
- `rental` may have zero or more `payment` records. Payment aggregation ensures **one fact row per rental**.
- `film` and `category` are related through `film_category` (potentially many-to-many).
- Sakila addresses are normalized through `address -> city -> country`. The warehouse further uses one `dim_address` lookup referenced by store/customer instead of replicating full addresses in the fact; this is a small snowflake extension around the core star.

### Target model

See [`diagrams/star_schema.png`](diagrams/star_schema.png) and [`diagrams/star_schema.svg`](diagrams/star_schema.svg).

**Central grain:** `fact_rental` = exactly one row per rental event. Keys include rental date, return date, film, store, customer, and inventory copy.

**Measures:** `amount` (sum of linked payment amounts), `rental_duration_days` (actual elapsed days; NULL until returned), `late_flag` (1 if returned after the film's allowed rental period; NULL if not returned), and `payment_count`.

**Dimensions:** `dim_date`, `dim_film`, `dim_store`, `dim_customer`, `dim_inventory`, plus category dimension / allocation bridge and shared address lookup.

**Store-level mart:** `mart_store_day` (store × rental date); optional slice mart `mart_store_category_day` (store × rental date × category, with weighted measures for multi-category films).

## 4. Extract, transform, load — Steps 2 and 4

```text
Sakila OLTP database
   |-- rental --------> sakila_stg.stg_rental --------┐
   |-- payment -------> sakila_stg.stg_payment -------|--> transform / upsert
   |-- inventory -----> sakila_stg.stg_inventory -----┘       |
   |-- store, film, customer, address, category ------------> dimensions
                                                           |
                                                   sakila_dw.fact_rental
                                                           |
                                                daily store/category marts
                                                           |
                                                   Streamlit dashboard
```

Transformation rules:

- **Paid amount:** `SUM(payment.amount)` grouped by `rental_id` first, so multiple payment rows do not duplicate a rental.
- **Actual rental days:** elapsed seconds / 86,400, rounded to three decimal places. A missing return yields `NULL`.
- **Late return:** returned after `rental_date + film.rental_duration` calendar days. Unreturned rentals have a `NULL` late flag; this dashboard does not infer whether a still-open rental is overdue.
- **Revenue timing:** grouped by **rental date**, not payment date. Payments with `rental_id IS NULL` are intentionally excluded from this rental-based model.
- **Multi-category films:** allocation weights = 1 / number of categories attached to a film. This avoids double counting summed category revenue (subject to negligible decimal rounding).
- **Refresh behavior:** staging is fully reloaded. Dimensions and rentals are upserted; daily marts are rebuilt. Source deletes and historical inventory movement are not tracked. A production version would implement CDC, deletions, type-2 history, and stronger refresh isolation.

## 5. Setup — MySQL 8.0+ and Python 3.10+

### A. Install Sakila

Download the MySQL official sample database: <https://downloads.mysql.com/docs/sakila-db.zip>.

Extract and import the included schema and data SQL files:

```bash
mysql -u root -p < path/to/sakila-db/sakila-schema.sql
mysql -u root -p < path/to/sakila-db/sakila-data.sql
```

Alternatively, use MySQL Workbench's SQL editor. Verify that `sakila.rental` exists before proceeding.

### B. Build and populate the warehouse

From the root of this project:

```bash
mysql -u root -p < sql/01_schema.sql
mysql -u root -p < sql/02_etl.sql
mysql -u root -p < sql/03_validation_and_queries.sql
```

The account needs read permission on `sakila` and create/read/write permission on `sakila_stg` and `sakila_dw`.

On subsequent refreshes, run `02_etl.sql` again. `03_validation_and_queries.sql` is read-only.

### C. Run the dashboard

```bash
python -m pip install -r requirements.txt
```

Set the database connection in the environment. **Never commit a real password to source control.**

Linux / macOS shell:

```bash
export MYSQL_HOST=127.0.0.1
export MYSQL_PORT=3306
export MYSQL_USER=root
export MYSQL_PASSWORD='your-password'
export MYSQL_DATABASE=sakila_dw
streamlit run dashboard/app.py
```

Windows PowerShell:

```powershell
$env:MYSQL_HOST = '127.0.0.1'
$env:MYSQL_PORT = '3306'
$env:MYSQL_USER = 'root'
$env:MYSQL_PASSWORD = 'your-password'
$env:MYSQL_DATABASE = 'sakila_dw'
streamlit run dashboard/app.py
```

Streamlit prints a local URL such as `http://localhost:8501` to open in a browser. The dashboard automatically defaults to the historical date range actually present in the source rental data.

## 6. Dashboard design — Step 5

The app provides:

- **Filters:** rental start/end date and store selection.
- **KPIs:** total revenue, rental count, late-return %, and active-inventory-copy %.
- **Store comparison:** revenues by store, late-return bars, sortable performance table.
- **Category performance:** allocated revenue by film category and repeat-customer rate per store/category.
- **Inventory utilization:** active, idle and total copies; rentals per copy; least-used inventory list (zero-use toggle).

### Definitions you can include in the report

| Measure | Formula | Important caveat |
| --- | --- | --- |
| Store revenue | `SUM(fact_rental.amount)` | Rental-date attribution; excludes unlinked payments |
| Late-return % | `100 * count(late_flag=1) / count(returned rentals)` | Does not call an unreturned rental "late-returned" |
| Active-copy % | `100 * inventory copies rented at least once / total copies` | Snapshot-based, within chosen rental dates |
| Idle copies | `total copies - active copies` | A zero-rental copy may be too recently added; historical stock changes unknown |
| Rentals per copy | `number of rental events / total inventory copies` | Event-based utilization proxy, NOT occupied-time % |
| Category repeat-customer % | `100 * customers with >=2 rentals in category / unique category customers` | Computed at **store × category × selected date window** |

## 7. Quality checks

Run `sql/03_validation_and_queries.sql` to inspect:

1. staged rental count versus fact count (expected zero difference);
2. rental-linked payments versus fact and store mart revenue;
3. category revenue allocation reconciliation;
4. late-return rate by store;
5. category revenue and loyalty;
6. inventory copy utilization and zero-use stock.

**Data caveat:** Standard Sakila is demonstration data from historical rental periods. Use its actual date bounds instead of setting the dashboard to today's dates. No live business outcomes or measured results are claimed in this project bundle; the app calculates them when connected to your populated Sakila source.

## 8. Two-hour suggested classroom sequence

| Time | Activity | Student output |
| --- | --- | --- |
| 0–15 min | OLTP vs OLAP vs raw lake | Business architecture note |
| 15–40 min | Identify entities and draw star | Diagram + grain statement |
| 40–75 min | Build staging/warehouse and load data | SQL scripts + row-count checks |
| 75–105 min | Validate KPIs and store/category marts | SQL query output |
| 105–120 min | Launch dashboard and discuss insights | Dashboard screenshot + conclusions |

## 9. Suggested final submission

Include a screenshot of your **running** Streamlit dashboard, the star-schema PNG, all three SQL scripts, this README and 3–4 observations based on the query output from your own Sakila installation.

### Official reference

[MySQL Sakila Sample Database documentation](https://dev.mysql.com/doc/sakila/en/)  
[MySQL Sakila installation](https://dev.mysql.com/doc/sakila/en/sakila-installation.html)  
[MySQL rental table](https://dev.mysql.com/doc/sakila/en/sakila-structure-tables-rental.html)  
[MySQL payment table](https://dev.mysql.com/doc/sakila/en/sakila-structure-tables-payment.html)
