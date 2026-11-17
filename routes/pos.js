const os = require('os');
const crypto = require('crypto');
const router = require('express').Router();
const pool = require('../db');

const ALLOWED_PAYMENT_METHODS = new Set(['QRIS', 'CASH', 'DEBIT', 'CREDIT', 'EWALLET']);
const TAX_RATE = 0.10; // Pajak restoran / PB1 10%

function getInstanceName() {
  return process.env.APP_INSTANCE || os.hostname();
}

function parsePositiveInt(value) {
  const num = Number(value);
  return Number.isInteger(num) && num > 0 ? num : null;
}

// =========================================================================
// Endpoint Ringan (Read): GET /api/products
// Mendukung filter opsional ?category=Coffee&search=Latte
// =========================================================================
router.get('/api/products', async (req, res) => {
  const instance = getInstanceName();
  res.set('X-App-Container', instance);

  try {
    const conditions = [];
    const params = [];

    if (typeof req.query.category === 'string' && req.query.category.trim()) {
      params.push(req.query.category.trim());
      conditions.push(`LOWER(category) = LOWER($${params.length})`);
    }

    if (typeof req.query.search === 'string' && req.query.search.trim()) {
      params.push(`%${req.query.search.trim()}%`);
      conditions.push(`name ILIKE $${params.length}`);
    }

    const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
    const { rows } = await pool.query(
      `SELECT id, sku, name, category, price, stock, is_available, created_at
       FROM products
       ${whereClause}
       ORDER BY id ASC`,
      params
    );

    console.log(`[${instance}] GET /api/products -> ${rows.length} items`);
    res.json({
      served_by: instance,
      count: rows.length,
      data: rows
    });
  } catch (err) {
    console.error(`[${instance}] Error GET /api/products:`, err.message);
    res.status(500).json({ error: 'Terjadi kesalahan internal saat mengambil katalog produk' });
  }
});

// =========================================================================
// Endpoint Ringan (Read): GET /api/products/:id
// =========================================================================
router.get('/api/products/:id', async (req, res) => {
  const instance = getInstanceName();
  res.set('X-App-Container', instance);

  const productId = parsePositiveInt(req.params.id);
  if (!productId) {
    return res.status(400).json({ error: 'Parameter id produk harus berupa bilangan bulat positif' });
  }

  try {
    const { rows } = await pool.query(
      'SELECT id, sku, name, category, price, stock, is_available, created_at FROM products WHERE id = $1',
      [productId]
    );
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Produk tidak ditemukan' });
    }
    res.json({ served_by: instance, data: rows[0] });
  } catch (err) {
    console.error(`[${instance}] Error GET /api/products/${productId}:`, err.message);
    res.status(500).json({ error: 'Terjadi kesalahan internal saat mengambil detail produk' });
  }
});

// =========================================================================
// Endpoint Berat (Write ACID + Row Locking): POST /api/transactions
// Memproses checkout kasir: validasi input, lock stok FOR UPDATE, hitung PB1 10%,
// kurangi stok, dan simpan transaksi secara atomik.
// =========================================================================
router.post('/api/transactions', async (req, res) => {
  const instance = getInstanceName();
  res.set('X-App-Container', instance);

  const productId = parsePositiveInt(req.body.product_id);
  const quantity = parsePositiveInt(req.body.quantity);

  if (!productId || !quantity || quantity > 1000) {
    return res.status(400).json({
      error: 'Validasi gagal: product_id dan quantity (1-1000) harus berupa bilangan bulat positif'
    });
  }

  const rawMethod = typeof req.body.payment_method === 'string'
    ? req.body.payment_method.trim().toUpperCase()
    : 'QRIS';
  if (!ALLOWED_PAYMENT_METHODS.has(rawMethod)) {
    return res.status(400).json({
      error: 'Validasi gagal: payment_method harus salah satu dari QRIS, CASH, DEBIT, CREDIT, atau EWALLET'
    });
  }

  const cashierName = typeof req.body.cashier_name === 'string' && req.body.cashier_name.trim()
    ? req.body.cashier_name.trim().slice(0, 100)
    : 'Kasir 01';
  const tableNo = typeof req.body.table_no === 'string' && req.body.table_no.trim()
    ? req.body.table_no.trim().slice(0, 20)
    : 'Takeaway';

  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    // Kunci baris produk (Row-level lock) agar stok aman dari race condition antar-kasir
    const productRes = await client.query(
      'SELECT id, sku, name, price, stock, is_available FROM products WHERE id = $1 FOR UPDATE',
      [productId]
    );

    if (productRes.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Produk tidak ditemukan' });
    }

    const product = productRes.rows[0];

    if (!product.is_available) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: `Produk '${product.name}' sedang tidak tersedia` });
    }

    if (product.stock < quantity) {
      await client.query('ROLLBACK');
      return res.status(409).json({
        error: `Stok '${product.name}' tidak mencukupi (tersedia: ${product.stock}, diminta: ${quantity})`
      });
    }

    await client.query(
      'UPDATE products SET stock = stock - $1 WHERE id = $2',
      [quantity, productId]
    );

    const unitPrice = Number(product.price);
    const subtotal = Number((unitPrice * quantity).toFixed(2));
    const taxAmount = Number((subtotal * TAX_RATE).toFixed(2));
    const totalPrice = Number((subtotal + taxAmount).toFixed(2));
    const randomSuffix = crypto.randomBytes(2).toString('hex').toUpperCase();
    const invoiceNo = `INV-${Date.now().toString().slice(-6)}-${randomSuffix}`;

    const insertRes = await client.query(
      `INSERT INTO transactions
         (invoice_no, product_id, quantity, unit_price, subtotal, tax_amount, total_price, payment_method, cashier_name, table_no, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'PAID')
       RETURNING *`,
      [invoiceNo, productId, quantity, unitPrice, subtotal, taxAmount, totalPrice, rawMethod, cashierName, tableNo]
    );

    await client.query('COMMIT');

    console.log(`[${instance}] POST /api/transactions ${invoiceNo} (${product.name} x${quantity})`);
    res.status(201).json({
      message: 'Transaksi POS Kafe berhasil dicatat',
      served_by: instance,
      transaction: insertRes.rows[0],
      item_details: {
        sku: product.sku,
        product_name: product.name,
        unit_price: product.price,
        quantity,
        remaining_stock: product.stock - quantity
      }
    });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    console.error(`[${instance}] Error POST /api/transactions:`, err.message);
    res.status(500).json({ error: 'Terjadi kesalahan internal saat memproses transaksi' });
  } finally {
    client.release();
  }
});

// =========================================================================
// Endpoint Audit Riwayat Transaksi: GET /api/transactions
// =========================================================================
router.get('/api/transactions', async (req, res) => {
  const instance = getInstanceName();
  res.set('X-App-Container', instance);

  const requestedLimit = parsePositiveInt(req.query.limit);
  const limit = requestedLimit ? Math.min(requestedLimit, 100) : 20;

  try {
    const { rows } = await pool.query(
      `SELECT t.id, t.invoice_no, p.sku, p.name AS product_name, t.quantity,
              t.unit_price, t.subtotal, t.tax_amount, t.total_price,
              t.payment_method, t.cashier_name, t.table_no, t.status, t.created_at
       FROM transactions t
       JOIN products p ON p.id = t.product_id
       ORDER BY t.id DESC
       LIMIT $1`,
      [limit]
    );
    res.json({ served_by: instance, count: rows.length, data: rows });
  } catch (err) {
    console.error(`[${instance}] Error GET /api/transactions:`, err.message);
    res.status(500).json({ error: 'Terjadi kesalahan internal saat mengambil riwayat transaksi' });
  }
});

// =========================================================================
// Endpoint Agregasi Laporan Penjualan: GET /api/transactions/summary
// =========================================================================
router.get('/api/transactions/summary', async (req, res) => {
  const instance = getInstanceName();
  res.set('X-App-Container', instance);

  try {
    const summaryRes = await pool.query(
      `SELECT COUNT(*)::int AS total_transactions,
              COALESCE(SUM(quantity), 0)::int AS total_items_sold,
              COALESCE(SUM(subtotal), 0)::numeric(12,2) AS total_subtotal,
              COALESCE(SUM(tax_amount), 0)::numeric(12,2) AS total_tax,
              COALESCE(SUM(total_price), 0)::numeric(12,2) AS total_revenue
       FROM transactions
       WHERE status = 'PAID'`
    );

    const topProductsRes = await pool.query(
      `SELECT p.id, p.sku, p.name, p.category,
              SUM(t.quantity)::int AS qty_sold,
              SUM(t.total_price)::numeric(12,2) AS revenue
       FROM transactions t
       JOIN products p ON p.id = t.product_id
       WHERE t.status = 'PAID'
       GROUP BY p.id, p.sku, p.name, p.category
       ORDER BY qty_sold DESC, revenue DESC
       LIMIT 5`
    );

    res.json({
      served_by: instance,
      summary: summaryRes.rows[0],
      top_products: topProductsRes.rows
    });
  } catch (err) {
    console.error(`[${instance}] Error GET /api/transactions/summary:`, err.message);
    res.status(500).json({ error: 'Terjadi kesalahan internal saat menyusun ringkasan transaksi' });
  }
});

module.exports = router;
