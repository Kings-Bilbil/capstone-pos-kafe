# Capstone Project Komputasi Awan — Kasus 10: Aplikasi Kasir (POS) Kafe

Integrasi Application Tier, Database Cloud, Load Balancing, CI/CD Pipeline, Monitoring/Observability, dan Cloud Security Hardening pada Infrastruktur VPS Ubuntu.

- **Mata Kuliah:** Komputasi Awan (3 SKS) — Pertemuan 14 (UAS)
- **Program Studi:** Sistem Informasi, FMIPA, Universitas Tanjungpura
- **Dosen Pengampu:** Syahru Rahmayuda, S.Kom., M.Kom.
- **Studi Kasus:** Kasus 10 — Aplikasi Kasir (POS) Kafe (F&B / Retail)
- **Referensi Repository:** Diadaptasi dari [TheUnknown550/POS-System](https://github.com/TheUnknown550/POS-System) (frontend dihapus, backend disesuaikan ke arsitektur stateless G.3 modul dengan `pg` + PostgreSQL 16)
- **Algoritma Load Balancing:** Least Connection (`least_conn`)

---

## 1. Struktur Proyek

```text
capstone-pos-kafe/
├── server.js                    # Entry point Express 4 + Helmet.js (/health)
├── db.js                        # Pool koneksi PostgreSQL via DATABASE_URL
├── routes/
│   └── pos.js                   # Endpoint katalog produk & transaksi POS ACID
├── schema.sql                   # Skema 2 tabel (products, transactions) + seed menu kafe
├── package.json                 # Dependensi standar modul (express, pg, helmet, dotenv)
├── Dockerfile                   # Image Node.js 20 Alpine
├── docker-compose.yml           # Orkestrasi app1, app2, db, nginx, node-exporter, prometheus, grafana
├── nginx.conf                   # Reverse proxy + Load Balancer (least_conn) + security headers
├── prometheus.yml               # Konfigurasi scrape Prometheus & Node Exporter
├── risk-register.md             # Risk Register & mitigasi risiko (7 risiko)
├── .env.example                 # Template variabel lingkungan database
├── .gitignore                   # Proteksi .env, node_modules, dan file backup .sql
└── .github/
    └── workflows/
        └── deploy.yml           # CI/CD GitHub Actions (build -> test -> deploy via SSH)
```

---

## 2. Justifikasi Pemilihan Load Balancing (`least_conn`)

1. **Karakteristik Beban Kerja POS Kafe:**
   - `GET /api/products` adalah request pembacaan katalog menu yang ringan dan cepat.
   - `POST /api/transactions` adalah request penulisan transaksi kasir yang lebih berat karena menjalankan transaksi database ACID (`BEGIN ... COMMIT`), penguncian baris stok (`SELECT ... FOR UPDATE`), validasi stok, pembaruan stok produk, penghitungan pajak PB1 10%, serta pencatatan faktur transaksi.
2. **Algoritma Dipilih:** **Least Connection (`least_conn`)**.
3. **Alasan Kesesuaian:** Karena durasi pemrosesan antar-endpoint bervariasi, `least_conn` mengarahkan request baru ke container (`app1` atau `app2`) dengan jumlah koneksi aktif paling sedikit sehingga mencegah penumpukan antrean saat salah satu container memproses checkout.
4. **Konsekuensi Alternatif:**
   - **Round Robin:** Membagi request secara bergilir tanpa mempertimbangkan apakah salah satu backend masih sibuk menangani transaksi berat, sehingga berisiko menambah antrean latensi.
   - **IP Hash:** Beberapa terminal kasir/tablet pelayan di satu kafe umumnya berbagi satu IP publik Wi-Fi (NAT), sehingga seluruh trafik berisiko diarahkan ke satu container saja sementara container lainnya menganggur.

---

## 3. Daftar Endpoint API

| Method | Endpoint | Deskripsi | Karakteristik Beban |
|:------:|:---------|:----------|:--------------------|
| `GET` | `/health` | Health check status container Express | Ringan |
| `GET` | `/api/products` | Menampilkan katalog menu kafe (mendukung `?category=` & `?search=`) | Ringan (Read) |
| `GET` | `/api/products/:id` | Menampilkan detail satu produk berdasarkan ID | Ringan (Read) |
| `POST` | `/api/transactions` | Mencatat transaksi pembelian & mengurangi stok secara atomik | Berat (Write ACID) |
| `GET` | `/api/transactions` | Menampilkan riwayat transaksi terbaru (`?limit=`) | Menengah (JOIN) |
| `GET` | `/api/transactions/summary` | Ringkasan total penjualan dan 5 menu terlaris | Menengah (Agregasi) |

---

## 4. Menjalankan di VPS Ubuntu

1. Salin `.env.example` menjadi `.env` di `/var/www/capstone` dan sesuaikan kredensial PostgreSQL:
   ```bash
   cp .env.example .env
   ```
2. Jalankan seluruh layanan multi-container:
   ```bash
   docker compose up -d --build
   docker compose ps
   ```
3. Backup manual database PostgreSQL (`pg_dump`):
   ```bash
   docker compose exec db pg_dump -U pos_admin -d capstone > backup_capstone_$(date +%Y%m%d).sql
   ```
