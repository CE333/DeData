# راهنمای دیپلوی در Remix

۱. هر دو فایل داخل `src/` رو در Remix باز کن (ترتیب کامپایل مهم نیست).
۲. Compiler: نسخه 0.8.24، Optimization فعال با runs=200. در صورت خطای Stack too deep گزینه viaIR رو فعال کن.
۳. دیپلوی اول: `DeDataProtocol` با ورودی‌های treasury، arbiter، reportBond (مثلاً 10000000000000000 = 0.01 BNB).
۴. آدرس قرارداد رو کپی کن.
۵. دیپلوی دوم: `DeDataProvenance` با ورودی آدرس مرحله ۴. (`IDeDataProtocol` رو دیپلوی نکن، فقط interface است.)
۶. شبکه تست: opBNB Testnet (5611) یا BSC Testnet (97).

در Remix VM زمان جلو نمی‌رود؛ برای تست مسیرهای زمانی از testnet یا Foundry با vm.warp استفاده کن.
