-- ============================================================
-- DATABASE PSIKOTEST KARYAWAN - SUPABASE
-- ============================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABLE: peserta (Participants)
-- ============================================================
CREATE TABLE peserta (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  kode_unik VARCHAR(10) UNIQUE NOT NULL,
  nama VARCHAR(100) NOT NULL,
  email VARCHAR(100),
  jabatan VARCHAR(100),
  departemen VARCHAR(100),
  tanggal_lahir DATE,
  jenis_kelamin VARCHAR(10) CHECK (jenis_kelamin IN ('Laki-laki', 'Perempuan')),
  status VARCHAR(20) DEFAULT 'belum' CHECK (status IN ('belum', 'sedang', 'selesai')),
  sesi_mulai TIMESTAMPTZ,
  sesi_selesai TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by UUID
);

-- ============================================================
-- TABLE: soal (Questions)
-- ============================================================
CREATE TABLE soal (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  kode_soal VARCHAR(20) UNIQUE NOT NULL,
  kategori VARCHAR(50) NOT NULL, -- 'kepribadian', 'logika', 'numerik', 'verbal'
  sub_kategori VARCHAR(50),
  pertanyaan TEXT NOT NULL,
  pilihan_a TEXT,
  pilihan_b TEXT,
  pilihan_c TEXT,
  pilihan_d TEXT,
  pilihan_e TEXT,
  jawaban_benar VARCHAR(1), -- NULL jika pertanyaan kepribadian (tidak ada benar/salah)
  bobot INT DEFAULT 1,
  urutan INT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- TABLE: sesi_tes (Test Session)
-- ============================================================
CREATE TABLE sesi_tes (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  peserta_id UUID REFERENCES peserta(id) ON DELETE CASCADE,
  waktu_mulai TIMESTAMPTZ DEFAULT NOW(),
  waktu_selesai TIMESTAMPTZ,
  durasi_menit INT DEFAULT 60,
  batas_waktu TIMESTAMPTZ, -- waktu_mulai + durasi
  status VARCHAR(20) DEFAULT 'aktif' CHECK (status IN ('aktif', 'selesai', 'timeout')),
  soal_terakhir INT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- TABLE: jawaban (Answers)
-- ============================================================
CREATE TABLE jawaban (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  sesi_id UUID REFERENCES sesi_tes(id) ON DELETE CASCADE,
  peserta_id UUID REFERENCES peserta(id) ON DELETE CASCADE,
  soal_id UUID REFERENCES soal(id) ON DELETE CASCADE,
  jawaban_dipilih VARCHAR(1), -- 'a', 'b', 'c', 'd', 'e'
  adalah_benar BOOLEAN,
  waktu_jawab TIMESTAMPTZ DEFAULT NOW(),
  durasi_detik INT, -- berapa lama menjawab soal ini
  UNIQUE(sesi_id, soal_id)
);

-- ============================================================
-- TABLE: hasil (Results)
-- ============================================================
CREATE TABLE hasil (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  peserta_id UUID REFERENCES peserta(id) ON DELETE CASCADE,
  sesi_id UUID REFERENCES sesi_tes(id) ON DELETE CASCADE,
  skor_total INT DEFAULT 0,
  skor_kepribadian INT DEFAULT 0,
  skor_logika INT DEFAULT 0,
  skor_numerik INT DEFAULT 0,
  skor_verbal INT DEFAULT 0,
  persentase DECIMAL(5,2),
  kategori_hasil VARCHAR(50), -- 'Sangat Baik', 'Baik', 'Cukup', 'Kurang'
  rekomendasi TEXT,
  detail_hasil JSONB, -- Data detail per kategori
  is_lulus BOOLEAN,
  waktu_kalkulasi TIMESTAMPTZ DEFAULT NOW(),
  reviewed_by UUID,
  catatan_admin TEXT
);

-- ============================================================
-- TABLE: admin (Admin Users)
-- ============================================================
CREATE TABLE admin (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  email VARCHAR(100) UNIQUE NOT NULL,
  nama VARCHAR(100) NOT NULL,
  role VARCHAR(20) DEFAULT 'admin' CHECK (role IN ('superadmin', 'admin', 'viewer')),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- INDEXES for Performance
-- ============================================================
CREATE INDEX idx_peserta_kode ON peserta(kode_unik);
CREATE INDEX idx_peserta_status ON peserta(status);
CREATE INDEX idx_soal_kategori ON soal(kategori);
CREATE INDEX idx_soal_active ON soal(is_active);
CREATE INDEX idx_jawaban_sesi ON jawaban(sesi_id);
CREATE INDEX idx_jawaban_peserta ON jawaban(peserta_id);
CREATE INDEX idx_hasil_peserta ON hasil(peserta_id);
CREATE INDEX idx_sesi_peserta ON sesi_tes(peserta_id);

-- ============================================================
-- FUNCTION: Generate Kode Unik
-- ============================================================
CREATE OR REPLACE FUNCTION generate_kode_unik()
RETURNS VARCHAR AS $$
DECLARE
  kode VARCHAR(10);
  exists_check INT;
BEGIN
  LOOP
    -- Format: PSI-XXXXX (huruf + angka random)
    kode := 'PSI-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT), 1, 5));
    SELECT COUNT(*) INTO exists_check FROM peserta WHERE kode_unik = kode;
    EXIT WHEN exists_check = 0;
  END LOOP;
  RETURN kode;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNCTION: Kalkulasi Hasil Otomatis
-- ============================================================
CREATE OR REPLACE FUNCTION kalkulasi_hasil(p_sesi_id UUID)
RETURNS VOID AS $$
DECLARE
  v_peserta_id UUID;
  v_skor_total INT := 0;
  v_skor_kepribadian INT := 0;
  v_skor_logika INT := 0;
  v_skor_numerik INT := 0;
  v_skor_verbal INT := 0;
  v_total_soal INT := 0;
  v_persentase DECIMAL(5,2);
  v_kategori VARCHAR(50);
  v_rekomendasi TEXT;
  v_lulus BOOLEAN;
BEGIN
  -- Ambil peserta_id
  SELECT peserta_id INTO v_peserta_id FROM sesi_tes WHERE id = p_sesi_id;
  
  -- Hitung skor per kategori
  SELECT 
    COALESCE(SUM(CASE WHEN s.kategori = 'kepribadian' AND j.adalah_benar THEN s.bobot ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN s.kategori = 'logika' AND j.adalah_benar THEN s.bobot ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN s.kategori = 'numerik' AND j.adalah_benar THEN s.bobot ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN s.kategori = 'verbal' AND j.adalah_benar THEN s.bobot ELSE 0 END), 0),
    COUNT(DISTINCT j.soal_id)
  INTO v_skor_kepribadian, v_skor_logika, v_skor_numerik, v_skor_verbal, v_total_soal
  FROM jawaban j
  JOIN soal s ON j.soal_id = s.id
  WHERE j.sesi_id = p_sesi_id;
  
  v_skor_total := v_skor_kepribadian + v_skor_logika + v_skor_numerik + v_skor_verbal;
  
  -- Hitung persentase
  SELECT COUNT(*) INTO v_total_soal FROM soal WHERE is_active = TRUE;
  v_persentase := CASE WHEN v_total_soal > 0 THEN (v_skor_total::DECIMAL / v_total_soal * 100) ELSE 0 END;
  
  -- Tentukan kategori
  IF v_persentase >= 85 THEN
    v_kategori := 'Sangat Baik';
    v_rekomendasi := 'Kandidat sangat direkomendasikan. Menunjukkan kompetensi luar biasa di semua aspek.';
    v_lulus := TRUE;
  ELSIF v_persentase >= 70 THEN
    v_kategori := 'Baik';
    v_rekomendasi := 'Kandidat direkomendasikan. Memiliki kemampuan yang baik dan potensial untuk berkembang.';
    v_lulus := TRUE;
  ELSIF v_persentase >= 55 THEN
    v_kategori := 'Cukup';
    v_rekomendasi := 'Kandidat dapat dipertimbangkan dengan catatan perlu pembinaan lebih lanjut.';
    v_lulus := TRUE;
  ELSE
    v_kategori := 'Kurang';
    v_rekomendasi := 'Kandidat belum memenuhi standar minimum yang dipersyaratkan.';
    v_lulus := FALSE;
  END IF;
  
  -- Simpan hasil
  INSERT INTO hasil (peserta_id, sesi_id, skor_total, skor_kepribadian, skor_logika, skor_numerik, skor_verbal, persentase, kategori_hasil, rekomendasi, is_lulus, detail_hasil)
  VALUES (
    v_peserta_id, p_sesi_id, v_skor_total, v_skor_kepribadian, v_skor_logika, v_skor_numerik, v_skor_verbal,
    v_persentase, v_kategori, v_rekomendasi, v_lulus,
    jsonb_build_object(
      'kepribadian', v_skor_kepribadian,
      'logika', v_skor_logika,
      'numerik', v_skor_numerik,
      'verbal', v_skor_verbal,
      'persentase', v_persentase
    )
  )
  ON CONFLICT (peserta_id) DO UPDATE
  SET skor_total = EXCLUDED.skor_total,
      persentase = EXCLUDED.persentase,
      kategori_hasil = EXCLUDED.kategori_hasil,
      waktu_kalkulasi = NOW();
      
  -- Update status peserta
  UPDATE peserta SET status = 'selesai', sesi_selesai = NOW() WHERE id = v_peserta_id;
  UPDATE sesi_tes SET status = 'selesai', waktu_selesai = NOW() WHERE id = p_sesi_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================
ALTER TABLE peserta ENABLE ROW LEVEL SECURITY;
ALTER TABLE soal ENABLE ROW LEVEL SECURITY;
ALTER TABLE jawaban ENABLE ROW LEVEL SECURITY;
ALTER TABLE hasil ENABLE ROW LEVEL SECURITY;
ALTER TABLE sesi_tes ENABLE ROW LEVEL SECURITY;

-- Policy: Peserta hanya bisa lihat data sendiri (by kode_unik stored in session)
CREATE POLICY "peserta_select_own" ON peserta FOR SELECT USING (true);
CREATE POLICY "soal_select_active" ON soal FOR SELECT USING (is_active = true);
CREATE POLICY "jawaban_insert_own" ON jawaban FOR INSERT WITH CHECK (true);
CREATE POLICY "jawaban_select_own" ON jawaban FOR SELECT USING (true);
CREATE POLICY "hasil_select_own" ON hasil FOR SELECT USING (true);
CREATE POLICY "sesi_all" ON sesi_tes FOR ALL USING (true);

-- ============================================================
-- SAMPLE DATA: Soal Psikotest
-- ============================================================
INSERT INTO soal (kode_soal, kategori, pertanyaan, pilihan_a, pilihan_b, pilihan_c, pilihan_d, pilihan_e, jawaban_benar, urutan) VALUES
-- LOGIKA
('LOG001', 'logika', 'Jika semua A adalah B, dan semua B adalah C, maka...', 'Semua C adalah A', 'Semua A adalah C', 'Semua B adalah A', 'Tidak ada yang benar', NULL, 'b', 1),
('LOG002', 'logika', 'Angka berikutnya dalam deret 2, 4, 8, 16, ... adalah?', '24', '28', '32', '30', NULL, 'c', 2),
('LOG003', 'logika', 'Deret: 1, 1, 2, 3, 5, 8, ... angka berikutnya adalah?', '11', '12', '13', '14', NULL, 'c', 3),
-- NUMERIK
('NUM001', 'numerik', 'Berapa hasil dari 15% dari 240?', '36', '34', '38', '40', NULL, 'a', 4),
('NUM002', 'numerik', 'Jika harga barang naik 20% dari Rp 50.000, harga baru adalah?', 'Rp 55.000', 'Rp 60.000', 'Rp 65.000', 'Rp 70.000', NULL, 'b', 5),
('NUM003', 'numerik', 'Rata-rata dari 10, 20, 30, 40, 50 adalah?', '25', '30', '35', '40', NULL, 'b', 6),
-- VERBAL
('VER001', 'verbal', 'Antonim dari kata "EFISIEN" adalah?', 'Hemat', 'Boros', 'Cepat', 'Lambat', NULL, 'b', 7),
('VER002', 'verbal', 'Sinonim dari kata "ANTUSIAS" adalah?', 'Malas', 'Bersemangat', 'Ragu-ragu', 'Pasif', NULL, 'b', 8),
('VER003', 'verbal', 'PANAS : API = DINGIN : ?', 'Salju', 'Es Batu', 'Air', 'Hujan', NULL, 'a', 9),
-- KEPRIBADIAN (tidak ada jawaban benar)
('KEP001', 'kepribadian', 'Ketika menghadapi tekanan kerja yang tinggi, saya cenderung...', 'Tetap tenang dan fokus', 'Mencari bantuan rekan', 'Mengerjakan satu per satu', 'Merasa tertekan namun tetap bekerja', NULL, NULL, 10),
('KEP002', 'kepribadian', 'Dalam tim, saya lebih suka berperan sebagai...', 'Pemimpin yang mengarahkan', 'Anggota yang mendukung', 'Penengah konflik', 'Penganalisis situasi', NULL, NULL, 11),
('KEP003', 'kepribadian', 'Saya menggambarkan diri saya sebagai orang yang...', 'Sangat terorganisir', 'Kreatif dan fleksibel', 'Analitis dan detail', 'Komunikatif dan terbuka', NULL, NULL, 12);

-- ============================================================
-- SAMPLE DATA: Peserta
-- ============================================================
INSERT INTO peserta (kode_unik, nama, jabatan, departemen, email) VALUES
('PSI-DEMO1', 'Budi Santoso', 'Staff IT', 'Teknologi Informasi', 'budi@example.com'),
('PSI-DEMO2', 'Siti Rahayu', 'Manager HRD', 'Human Resources', 'siti@example.com'),
('PSI-DEMO3', 'Ahmad Fauzi', 'Analis Keuangan', 'Finance', 'ahmad@example.com');

-- ============================================================
-- VIEW: Rekap Hasil untuk Dashboard Admin
-- ============================================================
CREATE OR REPLACE VIEW v_dashboard_admin AS
SELECT 
  p.id AS peserta_id,
  p.kode_unik,
  p.nama,
  p.jabatan,
  p.departemen,
  p.email,
  p.status,
  p.sesi_mulai,
  p.sesi_selesai,
  h.skor_total,
  h.skor_kepribadian,
  h.skor_logika,
  h.skor_numerik,
  h.skor_verbal,
  h.persentase,
  h.kategori_hasil,
  h.is_lulus,
  h.rekomendasi,
  EXTRACT(EPOCH FROM (p.sesi_selesai - p.sesi_mulai))/60 AS durasi_menit,
  p.created_at
FROM peserta p
LEFT JOIN hasil h ON p.id = h.peserta_id
ORDER BY p.created_at DESC;
