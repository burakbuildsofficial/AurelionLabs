# Inkling Lab

Bu Mac'teki yerel GGUF modellerini (Inkling 2 Mini ve diğerleri) kullanmak ve sınamak için macOS uygulaması (SwiftUI, llama.cpp). Tasarım: app-ui-base (BugSafe teması, indigo).

## Çalıştırma

```
./scripts/build-app.sh          # build/InklingLab.app üretir
open build/InklingLab.app
```

Uygulama açılınca `llama-server`'ı kendisi başlatır, kapanınca durdurur (127.0.0.1:8001, yalnız bu Mac).

Varsayılan yollar (uygulamada Sunucu › Dosya yolları'ndan değişir):

| | |
|---|---|
| llama-server | `~/llama.cpp/build/bin/llama-server` (mainline, b12611+ gerekir) |
| Model | `~/models/inkling-2-mini/Inkling-2-Mini-UD-IQ3_XXS.gguf` |
| Resim (mmproj) | `~/models/inkling-2-mini/mmproj-F16.gguf` |

## Özellikler

- Model menüsü (üst çubuk): ~/models ve eklenen klasörlerdeki .gguf modeller, tek tıkla geçiş, bellekten kaldır/yükle; aynı klasörde mmproj varsa resim desteği otomatik
- Ayarlar sekmesi (⌘,): Modeller, ön ayar, örnekleme, sistem promptu, sunucu, görünüm (Sistem/Açık/Koyu tema + 5 ana renk)
- Sohbetler kenar çubuğunda: arama, sabitle, yeniden adlandır, Markdown olarak kaydet, sil

- Sohbet geçmişi: solda liste, arama, yeniden adlandır, sil (`~/Library/Application Support/InklingLab/conversations/`)
- Dosya ile soru: PDF, metin, Markdown, kod, JSON, CSV sürükle ya da ataşla ekle (en fazla ~13K token)
- Kod blokları ayrı kutuda, tek tıkla kopyala
- Testler › Önceki çalıştırmalar › Sonuç kartı: 1–2 çalıştırmayı 1600×900 PNG yapar, panoya kopyalar, İndirilenler'e kaydeder
- Akışlı sohbet, düşünme paneli, cevap başına hız/token ölçümü, kopyala, yeniden üret
- Resim: sürükle-bırak, yapıştır (⌘V), dosyadan seç; en uzun kenar 1024 px'e küçültülür
- Örnekleme: sıcaklık, top-p, min-p, top-k, en fazla token, sistem promptu
- Ön ayarlar: 4 hazır + kendi kayıtların (`~/Library/Application Support/InklingLab/presets.json`)
- Karşılaştır: aynı soru iki ön ayarla, sırayla, yan yana
- Sunucu: başlat/durdur/yeniden başlat, bağlam boyutu, resim desteği, canlı kayıt

Kısayollar: ⌘N yeni sohbet · ⌘. durdur · ⌘R yeniden üret · ⇧⌘T düşünmeyi göster/gizle · ⌘, ayarlar

## Yapı

```
Sources/InklingLab/
  App.swift                 pencere, menüler, kapanışta sunucuyu durdurma
  Design/Theme.swift        tüm renk/yazı/boşluk tokenları
  Design/Motion.swift       yay animasyonları, basılma stili
  Model/Models.swift        SamplingParams, Preset, ChatMessage, GenStats
  Services/ServerManager    llama-server süreci
  Services/LLMClient        /v1/chat/completions akışı (SSE)
  Services/LabStore         uygulama durumu
  Services/ImageLoader      resim küçültme / panodan okuma
  Views/                    Root, Chat, Inspector, Compare, Components
```

## Yapılacaklar

- [ ] **Atomic Engine'i ikinci motor olarak ekle** (2026-11-24'te internet yetmediği için ertelendi, indirmeler silindi)
  - Kod: `github.com/AtomicBot-ai/atomic-engine`, dal `codex/expert-weight-source` → `~/atomic-engine`, Metal derleme
  - Model: `AtomicChat/Inkling-2-Mini-GGUF` → `Inkling-2-Mini-AD-Q4_K.gguf` (16,5 GB) + `dspark-Inkling-2-Mini-Q8_0.gguf` (0,5 GB)
  - Uygulamaya motor seçici + `--engine-budget-mib` (24 GB için ~14436), sonra 27 test ve sonuç kartına 3. sütun
- [x] Sohbet geçmişini kaydet
- [x] Kod bloklarını ayrı kutuda göster (renklendirme henüz yok)
- [x] Testlerden tek tıkla sonuç kartı
