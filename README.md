# Lynt

Yazmaya ara verdiğinizde odaktaki desteklenen metin alanının yanında öneri gösteren, kişisel bir macOS İngilizce yazım yardımcısı. Manuel kısayol ve yapıştırma incelemesi de kullanılabilir. SwiftUI/AppKit menü çubuğu uygulaması; sunucu, hesap sistemi veya üçüncü taraf paket bağımlılığı yoktur.

Otomatik mod, macOS Accessibility üzerinden yalnızca odaktaki düzenlenebilir alanı izler; klavye olaylarını kaydetmez. Her sitedeki özel editörün bu arayüzü sunduğu garanti edilmez. Yürütülen testler ve gerçek editör desteğinin doğrulama durumu [TESTING.md](TESTING.md) içinde ayrı ayrı belirtilir.

## Çalıştırma

Gereksinimler: macOS 14+, Swift 6 araç zinciri; Xcode projesi için Xcode 16+. Geliştirme makinesinde macOS 26.6.2 / Xcode 26.3 / Swift 6.2.4 kullanıldı. Swift kaynakları 5 dil kipinde derlenir.

```sh
./Scripts/build-app.sh
open build/Lynt.app
```

Bu komut mevcut Mac mimarisi için release `.app` oluşturup yerel ad hoc imzalar. Dağıtım için noter onayı veya Developer ID imzası içermez. İsterseniz oluşan uygulamayı `~/Applications` dizinine kopyalayabilirsiniz. Accessibility iznini kullanmadan önce kalıcı bir konuma taşımak faydalıdır; yeniden derleme/imza değişimleri macOS izinlerini yeniden vermenizi gerektirebilir.

Xcode ile: `open Lynt.xcodeproj`, **Lynt** scheme, **My Mac**, Run. Core ve Platform modülleri aynı dizindeki Swift paketi üzerinden bağlanır. Testler için aşağıdaki SwiftPM komutunu kullanın; uygulama scheme'inde XCTest hedefleri bulunmaz.

```sh
swift test
xcodebuild -quiet -project Lynt.xcodeproj -scheme Lynt \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO build
```

Intel Mac'te `arch=x86_64` seçin. Paketleme betiği ve Xcode Debug yapısı ev sahibi mimarisini hedefler.

## İlk kullanım

1. **Local playground** ile API anahtarı olmadan dört kategorinin alt çizgilerini, Accept/Ignore ve son metin önizlemesini deneyin.
2. **Settings** içinden DeepSeek ve Mistral anahtarlarını ayrı ayrı kaydedin. Anahtarlar macOS Keychain'de tutulur; kaynak dosyaya veya `.env` dosyasına eklemeyin.
3. **Enable cloud review** seçeneğini açın. Yeni kurulumda kapalıdır; mevcut ayarınız korunur. **Automatic suggestions after typing** başlangıçta açıktır, ancak bulut inceleme ve Accessibility izni olmadan dış alanları izlemez. Otomatik mod açıkken uygun İngilizce parçaları her seferinde Review düğmesine basmadan API'ye gönderilebilir.
4. Settings'teki düğmeyle **Accessibility** iznini verin ve Lynt'in Settings/inceleme pencerelerini kapatın. Chrome veya başka bir uygulamada desteklenen metin alanına yazıp duraklayın. Varsayılan bekleme **1,2 saniye**; Settings'ten 0,8–5 saniye arasında ayarlanabilir. Öneri paneli alanın yanında açılır ve yazdığınız alanın klavye odağını almaz.
5. Panelde **Accept & apply** tek bir öneriyi doğrulayıp uygular; **Ignore** öneriyi atlar. Diğer öneriler yerelde yeniden eşlenir, kabul işlemi yeni API çağrısı başlatmaz. Güvenli yazma desteklenmiyorsa **Review / Copy** ile tam önizlemeyi açın. Hiçbir değişiklik kendiliğinden kabul edilmez; araç arama çalıştırmaz veya mesaj göndermez.

Menü çubuğundan otomatik önerileri durdurabilir veya **Pause in [uygulama]** ile bir uygulamayı hariç tutabilirsiniz. Hariç tutulan uygulamalar sonraki alan okumalarından önce kontrol edilir. Aynı metin sürümü tekrar gönderilmez; kapatılan panel metin değişene kadar bastırılır. Maliyeti sınırlamak için otomatik incelemeler arasında en az 4 saniye ve dakikada en fazla 8 inceleme sınırı vardır; dolayısıyla yoğun yazarken sonuç 1,2 saniyeden daha geç gelebilir. Aylık token bütçesi ayrıca uygulanır.

Manuel inceleme için uygulamaya metin yapıştırıp **Review English** seçin veya dış alanda `⌘⇧G` kullanın. Manuel yakalamada seçili metin önceliklidir; otomatik mod bütün odaktaki alanı inceler. Kısayol Settings'ten değiştirilebilir. Manuel önizlemede **Copy**, yalnızca kabul edilen sürümü kopyalar; **Apply accepted**, hedefi tekrar doğrular. Otomatik panelden açılmış bir incelemede değişiklikleri tek tek uygulayın; birden fazla kabul edilen değişikliği birleştirmek için Copy kullanın. **Inspect outgoing request** API çağrısı yapmadan hazırlanan İngilizce parçalarını gösterir. Hassas içerik için önce otomatik modu kapatıp bu önizlemeyi kullanın.

Accessibility izni dış uygulama alanlarını okumak/yazmak için gerekir; uygulama izni kendiliğinden istemez. Manuel yapıştırma ve yerel deneme için gerekmez. Desteklenmeyen veya değişmiş hedeflerde Copy kullanılır; klavye/paste taklidi yapılmaz. Uygulamayı yeniden derlemek veya başka konuma taşımak macOS'un izni yeniden istemesine neden olabilir.

## Sağlayıcılar ve fallback

- Varsayılan: **DeepSeek**, model `deepseek-flash`, `https://api.deepseek.com/chat/completions`.
- Alternatif: **Ministral 3 3B**, model `ministral-3b-2512`, `https://api.mistral.ai/v1/chat/completions`.
- Normalde tüm uygun İngilizce parçaları ve etkin kategoriler tek istekte gönderilir. Kredi bitmesi, kimlik doğrulama/rate limit/sunucu/ağ hatası, zaman aşımı veya geçersiz yanıt durumunda diğer yapılandırılmış sağlayıcı **en fazla bir kez** denenir. Aynı güvenli metin DTO'su kullanılır. Her yeni inceleme yeniden DeepSeek ile başlar.
- DeepSeek anahtarı yoksa ve fallback açıksa Mistral kullanılabilir. İki anahtarı da kaydetmek kredi bitmesi senaryosu için gereklidir. Fallback ayardan kapatılabilir; kullanılan sağlayıcı ve fallback bilgisi sonuçta gösterilir. İptal fallback başlatmaz.
- Model ve HTTPS endpoint ayarlanabilir. Endpoint değiştirirseniz API anahtarınızın ve uygun İngilizce metnin gönderileceği adresi de değiştirirsiniz. Yönlendirmeler, çerezler ve disk ağ önbelleği kapalıdır.
- Aylık token bütçesi ve çıktı sınırı yerel olarak uygulanır. Her iki olası deneme için gönderimden önce yer ayrılır; kullanım bilinmiyorsa ihtiyatlı tahmin sayılır. Bu sayaç sağlayıcı bakiyesi veya para birimi cinsinden fatura değildir. Canlı fiyat tahmini ve kalite/latans karşılaştırması sonraki aşamadadır.

Model varsayımları [DeepSeek resmî başlangıç dokümanı](https://api-docs.deepseek.com/) ve [Ministral 3 3B model kartından](https://docs.mistral.ai/models/ministral-3-3b-25-12) 3 Kasım 2026 tarihinde kontrol edildi. Fiyatlar kaynak koduna sabitlenmedi.

## Davranış ve sınırlar

Correctness (kırmızı), Clarity (mavi), Engagement (yeşil), Delivery & Tone (mor) panelde ve tam önizlemede kategori adıyla gösterilir. Renkli alt çizgiler Lynt'in tam önizlemesindedir; üçüncü taraf editörün içine canlı alt çizgi eklenmez. Hiçbir değişiklik önceden kabul edilmez. Çakışan öneriler alternatiflerdir. Ton varsayılanı **Preserve original**; bu hedefte Delivery yeniden yazımları reddedilir, ton tahmini gösterilebilir. Search modu yalnızca Correctness ister. Seçenek değişikliği mevcut incelemeyi iptal eder; otomatik modda editöre döndükten sonra yeni inceleme hazırlanır, manuel modda tekrar Review gerekir.

Koruma yerel ve ihtiyatlıdır: kod blokları, tanınan teknik aralıklar, sırlar, sayılar ve diğer diller çıkarılır. Türkçe/Azerbaycanca metin çevrilmez. Kısa veya belirsiz İngilizce parçalar atlanabilir; **Review as English** teknik korumayı kaldırmaz. HTTP blokları belgenin sonuna kadar, belirsiz `#` satırları ise tamamen korunabilir; bunun sonucu bazı İngilizce cümlelerin de atlanmasıdır.

Heuristikler tüm sırları, kod biçimlerini veya karışık dilleri kesin algılayamaz. Hassas içerik yazmadan önce otomatik/bulut işlemeyi kapatın veya ilgili uygulamayı hariç tutun. Model önerilerinin anlamı kusursuz koruduğu varsayılmaz; her değişiklik kullanıcı onayı gerektirir. Güvenli/parola ve salt okunur alanlar otomatik modda atlanır. Otomatik mod 20.000 UTF-16 biriminden büyük alanları atlar; manuel modda daha küçük bir seçim inceleyebilirsiniz.

Chrome'daki standart input/textarea/contenteditable alanları ve native uygulamalar Accessibility erişimlerine göre desteklenir. Gelişmiş rich-text, Google Docs, canvas tabanlı editörler ve IDE desteği garanti edilmez. Otomatik yazma ancak alanın değişmediği doğrulanabiliyor ve güvenli AX yazma yolu varsa sunulur. Çok satırlı/rich alanlarda desteklenen küçük aralık değiştirmesi tercih edilir; biçimlendirmeyi kaybedebilecek tüm-alan yazımı yapılmaz. Aksi halde Review / Copy kullanılır.

Uygulama menü çubuğunda çalışır. Kurulum/izin eksikse inceleme penceresi açılır. Lynt'in Settings veya inceleme penceresi açıkken dış uygulamaların otomatik incelemesi duraklatılır; ikisi de kapanınca devam eder. Manuel Cancel/kapatma inceleme referanslarını temizler; otomatik modda odak/hedef/metin değişimi eski sonucu geçersiz kılar. Prompt geçmişi, telemetri ve sunucu yoktur. Otomatik mod açıkken odaktaki alan değişimleri AX bildirimleri ve yaklaşık 0,65 saniyelik odaklı alan örneklemesiyle yerelde izlenir; tüm pencere ağacı veya klavye olayları taranmaz.

## Kaynaklar

- [ARCHITECTURE.md](ARCHITECTURE.md): modüller ve veri akışı.
- [SECURITY.md](SECURITY.md): gönderilen veri, koruma sınırları ve anahtar saklama.
- [TESTING.md](TESTING.md): gerçekten yürütülen testler ve henüz doğrulanmayan senaryolar.
- [ANDROID_PLAN.md](ANDROID_PLAN.md): paylaşılan JSON sözleşmeleriyle sonraki platform.
- [Contracts](Contracts): platformdan bağımsız istek/yanıt şemaları.
- [Asıl ürün dokümanı](Personal_English_Writing_Assistant_MVP_v2.md).

Son kullanıcı taleplerine uygun olarak otomatik DeepSeek/Ministral fallback ve yazmaya ara verince dış alanlarda otomatik öneri, asıl dokümandaki tek sağlayıcı/yalnızca manuel inceleme kurallarının yerine uygulanmıştır. Dağıtım/noter onayı, canlı sağlayıcı karşılaştırması ve tüm editörleri kapsayan uyumluluk tamamlanmış kabul edilmez.
