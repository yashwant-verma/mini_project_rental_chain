-- Validation + business question examples (run after ETL).
-- 1. Source/staging/warehouse count reconciliation (expected difference = 0).
SELECT
  (SELECT COUNT(*) FROM sakila_stg.stg_rental) AS staged_rentals,
  (SELECT COUNT(*) FROM sakila_dw.fact_rental) AS fact_rentals,
  (SELECT COUNT(*) FROM sakila_stg.stg_rental) -
  (SELECT COUNT(*) FROM sakila_dw.fact_rental) AS difference;

-- 2. Revenue reconciliation. Payments linked to rental only.
SELECT
  (SELECT ROUND(SUM(amount),2) FROM sakila_stg.stg_payment WHERE rental_id IS NOT NULL)
    AS linked_payment_revenue,
  (SELECT ROUND(SUM(amount),2) FROM sakila_dw.fact_rental) AS fact_revenue,
  (SELECT ROUND(SUM(revenue),2) FROM sakila_dw.mart_store_day) AS store_mart_revenue,
  (SELECT ROUND(SUM(allocated_revenue),2) FROM sakila_dw.mart_store_category_day)
    AS category_allocated_revenue;

-- 3. Store performance: late% denominator is ONLY completed returns.
SELECT s.store_name, a.city, a.country,
       SUM(m.rentals) AS rentals, ROUND(SUM(m.revenue),2) AS revenue,
       SUM(m.returned_rentals) AS returned_rentals,
       SUM(m.late_returns) AS late_returns,
       ROUND(100 * SUM(m.late_returns) / NULLIF(SUM(m.returned_rentals),0), 2) AS late_pct
FROM sakila_dw.mart_store_day m
JOIN sakila_dw.dim_store s ON s.store_key = m.store_key
JOIN sakila_dw.dim_address a ON a.address_id = s.address_id
GROUP BY s.store_key, s.store_name, a.city, a.country
ORDER BY revenue DESC;

-- 4. Revenue by store and category. Allocations avoid double-counting multi-category films.
SELECT s.store_name, c.category_name,
       ROUND(SUM(m.allocated_revenue),2) AS category_revenue,
       ROUND(SUM(m.allocated_rentals),2) AS allocated_rentals
FROM sakila_dw.mart_store_category_day m
JOIN sakila_dw.dim_store s ON s.store_key = m.store_key
JOIN sakila_dw.dim_category c ON c.category_key = m.category_key
GROUP BY s.store_key, s.store_name, c.category_key, c.category_name
ORDER BY s.store_key, category_revenue DESC;

-- 5. Inventory utilization (all historical rental dates).
-- active_copy_pct = copies rented at least once / all copies in that store.
-- rentals_per_copy = rental events / all inventory copies; NOT time-based occupancy.
SELECT s.store_name, COUNT(i.inventory_id) AS total_copies,
       SUM(CASE WHEN COALESCE(x.rentals,0) > 0 THEN 1 ELSE 0 END) AS active_copies,
       SUM(CASE WHEN COALESCE(x.rentals,0) = 0 THEN 1 ELSE 0 END) AS idle_copies,
       ROUND(100.0 * SUM(CASE WHEN COALESCE(x.rentals,0)>0 THEN 1 ELSE 0 END)
             / NULLIF(COUNT(i.inventory_id),0), 2) AS active_copy_pct,
       ROUND(SUM(COALESCE(x.rentals,0)) / NULLIF(COUNT(i.inventory_id),0),2)
             AS rentals_per_copy
FROM sakila_dw.dim_store s
LEFT JOIN sakila_dw.dim_inventory i ON i.store_key=s.store_key
LEFT JOIN (SELECT inventory_id, COUNT(*) AS rentals
           FROM sakila_dw.fact_rental GROUP BY inventory_id) x
       ON x.inventory_id=i.inventory_id
GROUP BY s.store_key, s.store_name;

-- 6. Repeat customer affinity. A repeat customer rented >=2 times from same category
-- and store during the chosen period (here: all history).
SELECT s.store_name, c.category_name,
       COUNT(*) AS unique_customers,
       SUM(CASE WHEN y.rentals_in_category >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
       ROUND(100.0 * SUM(CASE WHEN y.rentals_in_category >= 2 THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*),0), 2) AS repeat_customer_pct
FROM (
  SELECT fr.store_key, b.category_key, fr.customer_key,
         COUNT(*) AS rentals_in_category
  FROM sakila_dw.fact_rental fr
  JOIN sakila_dw.bridge_film_category b ON b.film_key=fr.film_key
  GROUP BY fr.store_key, b.category_key, fr.customer_key
) y
JOIN sakila_dw.dim_store s ON s.store_key=y.store_key
JOIN sakila_dw.dim_category c ON c.category_key=y.category_key
GROUP BY s.store_key, s.store_name, c.category_key, c.category_name
ORDER BY repeat_customer_pct DESC, repeat_customers DESC;

-- 7. 20 least-used copies, prioritizing never-rented inventory.
SELECT s.store_name, i.inventory_id, f.title,
       COUNT(fr.rental_id) AS rental_events
FROM sakila_dw.dim_inventory i
JOIN sakila_dw.dim_store s ON s.store_key = i.store_key
JOIN sakila_dw.dim_film f ON f.film_key = i.film_key
LEFT JOIN sakila_dw.fact_rental fr ON fr.inventory_id = i.inventory_id
GROUP BY s.store_key, s.store_name, i.inventory_id, f.title
ORDER BY rental_events, i.inventory_id
LIMIT 20;
