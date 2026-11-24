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

- [x] **Atomic Engine ikinci motor** (2026-11-25): adında `-AD-` geçen model seçilince kendiliğinden kullanılır
  - Kod: `~/atomic-engine`, dal `engine-development` (fb69fff), `build-metal/` (UI kapalı derlendi)
  - Model + DSpark taslak: `~/models/inkling-2-mini/atomic/`
  - Sınır: 4K bağlam, resim yok, yalnız AD dosyaları (Unsloth GGUF reddediliyor)
  - Ölçüm (4K, aynı 3 soru): Atomic 4-bit 22,6/19,5 t/s (sıcaklık 0/1) · 8,9 GB; llama.cpp 4-bit 15,0/14,8 · 14 GB; 3-bit 20,5/19,4 · 11,1 GB (`share/hiz-karsilastirma-4K.txt`)
  - Testler: 20/23 (görsel atlandı); iğne testleri 1K/2K'da "şifreyi paylaşamam" dedi, 3K'da bağlam doldu
- [ ] Samanlıkta iğne testindeki "kimseyle paylaşma" cümlesini kaldır (model talimata uyup reddediyor, test tasarım hatası)
- [x] Sohbet geçmişini kaydet
- [x] Kod bloklarını ayrı kutuda göster (renklendirme henüz yok)
- [x] Testlerden tek tıkla sonuç kartı
