-- =====================================================================
-- 00_load_data.sql
-- Loads the H&M Kaggle CSVs into a local DuckDB database.
--
-- Run from the repo root:
--   duckdb hm.duckdb -c ".read sql/00_load_data.sql"
--
--
--   *

-- ---------- Products ----------
DROP TABLE IF EXISTS articles;
CREATE TABLE articles AS
SELECT *
FROM read_csv('data/raw/articles.csv',
              header = true,
              types = {'article_id': 'VARCHAR',
                       'product_code': 'VARCHAR',
                       'colour_group_code': 'VARCHAR'});

-- ---------- Customers ----------
DROP TABLE IF EXISTS customers;
CREATE TABLE customers AS
SELECT *
FROM read_csv('data/raw/customers.csv',
              header = true,
              types = {'customer_id': 'VARCHAR',
                       'postal_code': 'VARCHAR'});

-- ---------- Transactions (~31.8M rows, one row = one unit sold) ----------
DROP TABLE IF EXISTS transactions;
CREATE TABLE transactions AS
SELECT *
FROM read_csv('data/raw/transactions_train.csv',
              header = true,
              columns = {'t_dat': 'DATE',
                         'customer_id': 'VARCHAR',
                         'article_id': 'VARCHAR',
                         'price': 'DOUBLE',
                         'sales_channel_id': 'INTEGER'});

-- ---------- Row counts ----------
SELECT 'articles'     AS table_name, COUNT(*) AS row_count FROM articles
UNION ALL
SELECT 'customers',    COUNT(*) FROM customers
UNION ALL
SELECT 'transactions', COUNT(*) FROM transactions;
