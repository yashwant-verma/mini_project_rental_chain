-- Project 8: Rental Chain Performance Warehouse
-- MySQL 8.0+ | Requires a populated source database named sakila.
-- Safe to re-run: creates databases and tables only if they do not exist.

CREATE DATABASE IF NOT EXISTS sakila_stg CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS sakila_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE sakila_stg;

CREATE TABLE IF NOT EXISTS stg_rental (
    rental_id INT PRIMARY KEY,
    rental_date DATETIME NOT NULL,
    inventory_id INT NOT NULL,
    customer_id INT NOT NULL,
    return_date DATETIME NULL,
    staff_id INT NOT NULL,
    last_update TIMESTAMP NULL,
    INDEX idx_stg_rental_inventory (inventory_id),
    INDEX idx_stg_rental_rental_date (rental_date)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_payment (
    payment_id INT PRIMARY KEY,
    customer_id INT NOT NULL,
    staff_id INT NOT NULL,
    rental_id INT NULL,
    amount DECIMAL(10,2) NOT NULL,
    payment_date DATETIME NOT NULL,
    last_update TIMESTAMP NULL,
    INDEX idx_stg_payment_rental (rental_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_inventory (
    inventory_id INT PRIMARY KEY,
    film_id INT NOT NULL,
    store_id INT NOT NULL,
    last_update TIMESTAMP NULL,
    INDEX idx_stg_inventory_film (film_id),
    INDEX idx_stg_inventory_store (store_id)
) ENGINE=InnoDB;

USE sakila_dw;

-- Reusable address lookup: no street address is duplicated in fact_rental.
-- This intentionally snowflakes only the address attributes around the core star.
CREATE TABLE IF NOT EXISTS dim_address (
    address_id INT PRIMARY KEY,
    address_line1 VARCHAR(100) NOT NULL,
    address_line2 VARCHAR(100) NULL,
    district VARCHAR(100) NOT NULL,
    city VARCHAR(100) NOT NULL,
    country VARCHAR(100) NOT NULL,
    postal_code VARCHAR(20) NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dim_date (
    date_key INT PRIMARY KEY, -- YYYYMMDD
    full_date DATE NOT NULL UNIQUE,
    calendar_year SMALLINT NOT NULL,
    calendar_quarter TINYINT NOT NULL,
    calendar_month TINYINT NOT NULL,
    month_name VARCHAR(12) NOT NULL,
    day_of_month TINYINT NOT NULL,
    day_of_week TINYINT NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dim_film (
    film_key INT AUTO_INCREMENT PRIMARY KEY,
    film_id INT NOT NULL UNIQUE,
    title VARCHAR(255) NOT NULL,
    release_year SMALLINT NULL,
    rating VARCHAR(10) NULL,
    allowed_rental_days INT NOT NULL,
    rental_rate DECIMAL(10,2) NOT NULL,
    film_length_minutes INT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dim_category (
    category_key INT AUTO_INCREMENT PRIMARY KEY,
    category_id INT NOT NULL UNIQUE,
    category_name VARCHAR(50) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dim_store (
    store_key INT AUTO_INCREMENT PRIMARY KEY,
    store_id INT NOT NULL UNIQUE,
    store_name VARCHAR(60) NOT NULL,
    address_id INT NOT NULL,
    manager_name VARCHAR(120) NULL,
    CONSTRAINT fk_store_address FOREIGN KEY (address_id) REFERENCES dim_address(address_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL UNIQUE,
    customer_name VARCHAR(120) NOT NULL,
    email VARCHAR(100) NULL,
    active TINYINT NOT NULL,
    home_store_id INT NOT NULL,
    address_id INT NOT NULL,
    CONSTRAINT fk_customer_address FOREIGN KEY (address_id) REFERENCES dim_address(address_id)
) ENGINE=InnoDB;

-- Includes inventory copies with zero rentals, required for idle inventory metrics.
CREATE TABLE IF NOT EXISTS dim_inventory (
    inventory_id INT PRIMARY KEY,
    film_key INT NOT NULL,
    store_key INT NOT NULL,
    CONSTRAINT fk_inventory_film FOREIGN KEY (film_key) REFERENCES dim_film(film_key),
    CONSTRAINT fk_inventory_store FOREIGN KEY (store_key) REFERENCES dim_store(store_key),
    INDEX idx_inventory_store (store_key)
) ENGINE=InnoDB;

-- Category allocation handles films with more than one category without double-counting revenue.
CREATE TABLE IF NOT EXISTS bridge_film_category (
    film_key INT NOT NULL,
    category_key INT NOT NULL,
    allocation_weight DECIMAL(12,8) NOT NULL,
    PRIMARY KEY (film_key, category_key),
    CONSTRAINT fk_bridge_film FOREIGN KEY (film_key) REFERENCES dim_film(film_key),
    CONSTRAINT fk_bridge_category FOREIGN KEY (category_key) REFERENCES dim_category(category_key)
) ENGINE=InnoDB;

-- Grain: ONE ROW PER RENTAL, even when several payments cover that rental.
CREATE TABLE IF NOT EXISTS fact_rental (
    rental_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    rental_id INT NOT NULL UNIQUE,
    rental_date_key INT NOT NULL,
    return_date_key INT NULL,
    film_key INT NOT NULL,
    store_key INT NOT NULL,
    customer_key INT NOT NULL,
    inventory_id INT NOT NULL,
    rental_date DATETIME NOT NULL,
    return_date DATETIME NULL,
    rental_duration_days DECIMAL(10,3) NULL,
    late_flag TINYINT NULL, -- NULL means rental not returned; excluded from return-late denominator.
    amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    payment_count INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_fact_rental_date FOREIGN KEY (rental_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_return_date FOREIGN KEY (return_date_key) REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_film FOREIGN KEY (film_key) REFERENCES dim_film(film_key),
    CONSTRAINT fk_fact_store FOREIGN KEY (store_key) REFERENCES dim_store(store_key),
    CONSTRAINT fk_fact_customer FOREIGN KEY (customer_key) REFERENCES dim_customer(customer_key),
    CONSTRAINT fk_fact_inventory FOREIGN KEY (inventory_id) REFERENCES dim_inventory(inventory_id),
    INDEX idx_fact_store_date (store_key, rental_date_key),
    INDEX idx_fact_film_date (film_key, rental_date_key),
    INDEX idx_fact_inventory_date (inventory_id, rental_date_key),
    INDEX idx_fact_customer_date (customer_key, rental_date_key)
) ENGINE=InnoDB;

-- Store-level data mart, grouped by RENTAL DATE (rental-attributed revenue).
CREATE TABLE IF NOT EXISTS mart_store_day (
    store_key INT NOT NULL,
    rental_date_key INT NOT NULL,
    rentals INT NOT NULL,
    revenue DECIMAL(14,2) NOT NULL,
    returned_rentals INT NOT NULL,
    late_returns INT NOT NULL,
    PRIMARY KEY (store_key, rental_date_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mart_store_category_day (
    store_key INT NOT NULL,
    rental_date_key INT NOT NULL,
    category_key INT NOT NULL,
    allocated_rentals DECIMAL(16,8) NOT NULL,
    allocated_revenue DECIMAL(18,8) NOT NULL,
    allocated_returns DECIMAL(16,8) NOT NULL,
    allocated_late_returns DECIMAL(16,8) NOT NULL,
    PRIMARY KEY (store_key, rental_date_key, category_key)
) ENGINE=InnoDB;
