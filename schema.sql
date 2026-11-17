-- Schema Database Capstone Project — Kasus 10: Aplikasi Kasir (POS) Kafe
-- Diadaptasi dari entitas produk & pesanan pada referensi TheUnknown550/POS-System
-- Target DBMS: PostgreSQL 16 Alpine

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(32) NOT NULL UNIQUE,
    name VARCHAR(120) NOT NULL,
    category VARCHAR(50) NOT NULL,
    price NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    stock INTEGER NOT NULL DEFAULT 50 CHECK (stock >= 0),
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transactions (
    id SERIAL PRIMARY KEY,
    invoice_no VARCHAR(50) NOT NULL UNIQUE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
    subtotal NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
    tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    total_price NUMERIC(12,2) NOT NULL CHECK (total_price >= 0),
    payment_method VARCHAR(20) NOT NULL CHECK (payment_method IN ('QRIS', 'CASH', 'DEBIT', 'CREDIT', 'EWALLET')),
    cashier_name VARCHAR(100) NOT NULL DEFAULT 'Kasir 01',
    table_no VARCHAR(20) NOT NULL DEFAULT 'Takeaway',
    status VARCHAR(20) NOT NULL DEFAULT 'PAID' CHECK (status IN ('PAID', 'CANCELLED')),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
CREATE INDEX IF NOT EXISTS idx_transactions_product_id ON transactions(product_id);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions(created_at DESC);

-- Seed Data Katalog Menu Kafe (Idempoten via ON CONFLICT)
INSERT INTO products (sku, name, category, price, stock) VALUES
('KFE-001', 'Espresso Single Origin', 'Coffee', 18000.00, 100),
('KFE-002', 'Iced Americano', 'Coffee', 22000.00, 100),
('KFE-003', 'Caramel Macchiato', 'Coffee', 28000.00, 80),
('KFE-004', 'Kopi Susu Gula Aren', 'Coffee', 25000.00, 120),
('KFE-005', 'Cafe Latte Oat Milk', 'Coffee', 32000.00, 75),
('NCF-001', 'Matcha Green Tea Latte', 'Non-Coffee', 26000.00, 90),
('NCF-002', 'Signature Chocolate Iced', 'Non-Coffee', 25000.00, 85),
('TEA-001', 'Earl Grey Artisan Tea', 'Tea', 20000.00, 60),
('PST-001', 'Croissant Butter Classic', 'Pastry', 24000.00, 45),
('FOD-001', 'Smoked Beef & Cheese Panini', 'Food', 38000.00, 35)
ON CONFLICT (sku) DO NOTHING;
