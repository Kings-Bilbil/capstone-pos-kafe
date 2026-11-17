# Risk Register: Infrastruktur Cloud Aplikasi Kasir (POS) Kafe

Dokumen ini merupakan bagian dari manajemen risiko aset informasi (CPMK5 / Sub-CPMK 5.2 / CPL07) untuk **Kasus 10 — Aplikasi Kasir (POS) Kafe** pada infrastruktur cloud berbasis VPS Ubuntu, Docker Multi-Container, Nginx Load Balancer (`least_conn`), PostgreSQL 16, dan GitHub Actions CI/CD.

## Matriks Kriteria Penilaian Risiko (Probability × Impact)

- **Probabilitas (P):** `1` Sangat Jarang · `2` Jarang · `3` Sedang · `4` Sering · `5` Sangat Sering
- **Dampak (I):** `1` Tidak Signifikan · `2` Minor · `3` Moderat · `4` Mayor · `5` Kritis/Katastropik
- **Tingkat Risiko (Skor = P × I):**
  - `15 – 25`: **Tinggi / Kritis (High)**
  - `8 – 14`: **Sedang (Medium)**
  - `1 – 7`: **Rendah (Low)**

---

## Tabel Risk Register (7 Risiko Teridentifikasi)

| No | Aset & Skenario Risiko | Kategori | P (1–5) | I (1–5) | Skor (P×I) | Tingkat | Rencana Mitigasi Teknis & Operasional |
|:--:|:-----------------------|:---------|:-------:|:-------:|:----------:|:-------:|:--------------------------------------|
| **1** | **Brute-force & Credential Stuffing SSH** pada VPS publik port 22 | Keamanan Infrastruktur | 4 | 4 | **16** | **Tinggi** | 1) Nonaktifkan login password (`PasswordAuthentication no` di `/etc/ssh/sshd_config`).<br>2) Wajib gunakan SSH Key-pair (Ed25519).<br>3) Aktifkan `fail2ban` jail `sshd` untuk auto-ban IP gagal login.<br>4) Terapkan UFW firewall hanya pada port 22, 80, dan 443. |
| **2** | **Race Condition Stok Produk saat Checkout Paralel** (dua kasir menjual stok sisa terakhir bersamaan) | Integritas Data (POS) | 3 | 5 | **15** | **Tinggi** | 1) Jalankan transaksi DB atomik `BEGIN ... COMMIT`.<br>2) Kunci baris produk dengan `SELECT ... FOR UPDATE` sebelum pengurangan stok.<br>3) Validasi `stock >= quantity` dan `ROLLBACK` otomatis bila gagal. |
| **3** | **SQL Injection & Payload Abuse** pada endpoint API (`GET /api/products`, `POST /api/transactions`) | Keamanan Aplikasi (OWASP A03) | 3 | 5 | **15** | **Tinggi** | 1) Gunakan parameterized query (`$1, $2, ...`) di library `pg` secara menyeluruh.<br>2) Validasi ketat tipe data integer positif & whitelist `payment_method`.<br>3) Aktifkan `Helmet.js` dan OWASP security headers Nginx (`X-Frame-Options`, `X-Content-Type-Options`, `CSP`). |
| **4** | **Ketidakseimbangan Beban & Antrean Latensi saat Jam Sibuk Kafe** (endpoint read vs write bercampur) | Kinerja & Ketersediaan | 4 | 3 | **12** | **Sedang** | 1) Terapkan horizontal scaling 2 container (`app1`, `app2`).<br>2) Konfigurasi Nginx Load Balancer dengan algoritma **Least Connection (`least_conn`)**.<br>3) Pantau metrik CPU, RAM, Disk, Network di Grafana + Prometheus secara berkala. |
| **5** | **Kehilangan Data Transaksi Kasir** akibat penghapusan container atau kerusakan disk VPS | Keberlangsungan Data | 2 | 5 | **10** | **Sedang** | 1) Isolasi DB PostgreSQL 16 dengan persistent named volume `pgdata`.<br>2) Lakukan backup manual/terjadwal rutin via `pg_dump`.<br>3) Simpan salinan backup di luar VPS lokal. |
| **6** | **Kebocoran Kredensial Database & SSH Key** melalui repositori GitHub publik | Keamanan Konfigurasi | 2 | 5 | **10** | **Sedang** | 1) Pisahkan kredensial ke file `.env` (berbasis `.env.example`) dan masukkan `.env` ke `.gitignore`.<br>2) Simpan `VPS_HOST`, `VPS_USER`, dan `VPS_SSH_KEY` secara terenkripsi di GitHub Actions Secrets.<br>3) Gunakan HTTPS TLS Let's Encrypt agar lalu lintas API terenkripsi. |
| **7** | **Single Container Crash & Unpatched OS Vulnerabilities** pada layanan aplikasi/OS | Reliabilitas & Patch | 3 | 3 | **9** | **Sedang** | 1) Atur `restart: unless-stopped` di `docker-compose.yml` dan failover otomatis Nginx antar-upstream.<br>2) Aktifkan `unattended-upgrades` di Ubuntu untuk patch keamanan otomatis. |

---

## Prosedur Pemantauan Berkelanjutan
1. Audit status firewall & jail SSH (`sudo ufw status`, `sudo fail2ban-client status sshd`) secara rutin.
2. Pantau target Prometheus (`node-exporter`) dan grafik utilisasi resource di Grafana (threshold kewaspadaan CPU/RAM > 80%).
3. Uji pemulihan hasil `pg_dump` secara berkala untuk memastikan backup dapat direstore.
