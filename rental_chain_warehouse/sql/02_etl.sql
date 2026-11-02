-- Project 8 ETL: full staging refresh and idempotent warehouse upserts.
-- Run AFTER 01_schema.sql. Source database sakila must already be populated.
-- Run again to pick up added rentals, payments, and completed returns.
-- Note: source DELETE propagation is not implemented in this teaching example.

-- EXTRACT -> STAGE (snapshot of the 3 transactional tables)
TRUNCATE TABLE sakila_stg.stg_payment;
TRUNCATE TABLE sakila_stg.stg_rental;
TRUNCATE TABLE sakila_stg.stg_inventory;

INSERT INTO sakila_stg.stg_rental
    (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update
FROM sakila.rental;

INSERT INTO sakila_stg.stg_payment
    (payment_id, customer_id, staff_id, rental_id, amount, payment_date, last_update)
SELECT payment_id, customer_id, staff_id, rental_id, amount, payment_date, last_update
FROM sakila.payment;

INSERT INTO sakila_stg.stg_inventory
    (inventory_id, film_id, store_id, last_update)
SELECT inventory_id, film_id, store_id, last_update
FROM sakila.inventory;

-- TRANSFORM -> LOAD warehouse
START TRANSACTION;

INSERT INTO sakila_dw.dim_address
    (address_id, address_line1, address_line2, district, city, country, postal_code)
SELECT a.address_id, a.address, a.address2, a.district, ci.city, co.country, a.postal_code
FROM sakila.address a
JOIN sakila.city ci ON ci.city_id = a.city_id
JOIN sakila.country co ON co.country_id = ci.country_id
WHERE 1=1
ON DUPLICATE KEY UPDATE
    address_line1 = VALUES(address_line1), address_line2 = VALUES(address_line2),
    district = VALUES(district), city = VALUES(city), country = VALUES(country),
    postal_code = VALUES(postal_code);

INSERT INTO sakila_dw.dim_store (store_id, store_name, address_id, manager_name)
SELECT s.store_id, CONCAT('Store ', s.store_id, ' - ', ci.city),
       s.address_id, CONCAT(m.first_name, ' ', m.last_name)
FROM sakila.store s
JOIN sakila.address a ON a.address_id = s.address_id
JOIN sakila.city ci ON ci.city_id = a.city_id
JOIN sakila.staff m ON m.staff_id = s.manager_staff_id
WHERE 1=1
ON DUPLICATE KEY UPDATE
    store_name = VALUES(store_name), address_id = VALUES(address_id),
    manager_name = VALUES(manager_name);

INSERT INTO sakila_dw.dim_customer
    (customer_id, customer_name, email, active, home_store_id, address_id)
SELECT customer_id, CONCAT(first_name, ' ', last_name), email,
       active, store_id, address_id
FROM sakila.customer
WHERE 1=1
ON DUPLICATE KEY UPDATE
    customer_name = VALUES(customer_name), email = VALUES(email),
    active = VALUES(active), home_store_id = VALUES(home_store_id),
    address_id = VALUES(address_id);

INSERT INTO sakila_dw.dim_film
    (film_id, title, release_year, rating, allowed_rental_days, rental_rate, film_length_minutes)
SELECT film_id, title, CAST(release_year AS UNSIGNED), rating,
       rental_duration, rental_rate, length
FROM sakila.film
WHERE 1=1
ON DUPLICATE KEY UPDATE
    title = VALUES(title), release_year = VALUES(release_year),
    rating = VALUES(rating), allowed_rental_days = VALUES(allowed_rental_days),
    rental_rate = VALUES(rental_rate), film_length_minutes = VALUES(film_length_minutes);

INSERT INTO sakila_dw.dim_category (category_id, category_name)
SELECT category_id, name FROM sakila.category
WHERE 1=1
ON DUPLICATE KEY UPDATE category_name = VALUES(category_name);

INSERT INTO sakila_dw.dim_inventory (inventory_id, film_key, store_key)
SELECT si.inventory_id, f.film_key, s.store_key
FROM sakila_stg.stg_inventory si
JOIN sakila_dw.dim_film f ON f.film_id = si.film_id
JOIN sakila_dw.dim_store s ON s.store_id = si.store_id
WHERE 1=1
ON DUPLICATE KEY UPDATE film_key = VALUES(film_key), store_key = VALUES(store_key);

-- ALL rental and return calendar dates must exist before loading fact FKs.
INSERT INTO sakila_dw.dim_date
    (date_key, full_date, calendar_year, calendar_quarter, calendar_month,
     month_name, day_of_month, day_of_week)
SELECT CAST(DATE_FORMAT(x.d, '%Y%m%d') AS UNSIGNED), x.d,
       YEAR(x.d), QUARTER(x.d), MONTH(x.d), MONTHNAME(x.d),
       DAYOFMONTH(x.d), DAYOFWEEK(x.d)
FROM (
    SELECT DATE(rental_date) AS d FROM sakila_stg.stg_rental
    UNION
    SELECT DATE(return_date) AS d FROM sakila_stg.stg_rental WHERE return_date IS NOT NULL
) x
WHERE x.d IS NOT NULL
ON DUPLICATE KEY UPDATE full_date = VALUES(full_date);

-- Refresh many-to-many allocations: each film's category weights sum approximately to 1.
DELETE FROM sakila_dw.bridge_film_category;
INSERT INTO sakila_dw.bridge_film_category (film_key, category_key, allocation_weight)
SELECT f.film_key, c.category_key,
       CAST(1.0 / category_counts.n_categories AS DECIMAL(12,8))
FROM sakila.film_category fc
JOIN (
    SELECT film_id, COUNT(*) AS n_categories
    FROM sakila.film_category
    GROUP BY film_id
) category_counts ON category_counts.film_id = fc.film_id
JOIN sakila_dw.dim_film f ON f.film_id = fc.film_id
JOIN sakila_dw.dim_category c ON c.category_id = fc.category_id;

-- Payment rollup FIRST, preventing fact duplication if there are multiple payments/rental.
-- Payment records without a rental_id are excluded from rental-attributed revenue.
INSERT INTO sakila_dw.fact_rental
    (rental_id, rental_date_key, return_date_key, film_key, store_key, customer_key,
     inventory_id, rental_date, return_date, rental_duration_days, late_flag,
     amount, payment_count)
SELECT r.rental_id,
       CAST(DATE_FORMAT(r.rental_date, '%Y%m%d') AS UNSIGNED),
       CASE WHEN r.return_date IS NULL THEN NULL
            ELSE CAST(DATE_FORMAT(r.return_date, '%Y%m%d') AS UNSIGNED) END,
       i.film_key, i.store_key, c.customer_key, r.inventory_id,
       r.rental_date, r.return_date,
       CASE WHEN r.return_date IS NULL THEN NULL
            ELSE GREATEST(0, ROUND(TIMESTAMPDIFF(SECOND, r.rental_date, r.return_date)/86400.0, 3)) END,
       CASE WHEN r.return_date IS NULL THEN NULL
            WHEN r.return_date > DATE_ADD(r.rental_date, INTERVAL f.allowed_rental_days DAY)
            THEN 1 ELSE 0 END,
       COALESCE(p.total_amount, 0), COALESCE(p.payment_count, 0)
FROM sakila_stg.stg_rental r
JOIN sakila_dw.dim_inventory i ON i.inventory_id = r.inventory_id
JOIN sakila_dw.dim_film f ON f.film_key = i.film_key
JOIN sakila_dw.dim_customer c ON c.customer_id = r.customer_id
LEFT JOIN (
    SELECT rental_id, SUM(amount) AS total_amount, COUNT(*) AS payment_count
    FROM sakila_stg.stg_payment
    WHERE rental_id IS NOT NULL
    GROUP BY rental_id
) p ON p.rental_id = r.rental_id
WHERE 1=1
ON DUPLICATE KEY UPDATE
    rental_date_key = VALUES(rental_date_key),
    return_date_key = VALUES(return_date_key), film_key = VALUES(film_key),
    store_key = VALUES(store_key), customer_key = VALUES(customer_key),
    inventory_id = VALUES(inventory_id), rental_date = VALUES(rental_date),
    return_date = VALUES(return_date), rental_duration_days = VALUES(rental_duration_days),
    late_flag = VALUES(late_flag), amount = VALUES(amount),
    payment_count = VALUES(payment_count);

-- STORE-LEVEL MART
DELETE FROM sakila_dw.mart_store_day;
INSERT INTO sakila_dw.mart_store_day
    (store_key, rental_date_key, rentals, revenue, returned_rentals, late_returns)
SELECT store_key, rental_date_key, COUNT(*), SUM(amount),
       SUM(CASE WHEN return_date IS NOT NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END)
FROM sakila_dw.fact_rental
GROUP BY store_key, rental_date_key;

-- CATEGORY MART. Counts and revenue are proportionally allocated if multi-category.
DELETE FROM sakila_dw.mart_store_category_day;
INSERT INTO sakila_dw.mart_store_category_day
    (store_key, rental_date_key, category_key, allocated_rentals, allocated_revenue,
     allocated_returns, allocated_late_returns)
SELECT fr.store_key, fr.rental_date_key, b.category_key,
       SUM(b.allocation_weight),
       SUM(fr.amount * b.allocation_weight),
       SUM(CASE WHEN fr.return_date IS NOT NULL THEN b.allocation_weight ELSE 0 END),
       SUM(CASE WHEN fr.late_flag = 1 THEN b.allocation_weight ELSE 0 END)
FROM sakila_dw.fact_rental fr
JOIN sakila_dw.bridge_film_category b ON b.film_key = fr.film_key
GROUP BY fr.store_key, fr.rental_date_key, b.category_key;

COMMIT;

SELECT 'ETL finished' AS status,
       (SELECT COUNT(*) FROM sakila_stg.stg_rental) AS staged_rentals,
       (SELECT COUNT(*) FROM sakila_dw.fact_rental) AS warehouse_rentals,
       (SELECT COUNT(*) FROM sakila_dw.dim_inventory) AS inventory_copies;
