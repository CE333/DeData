# مرحله ۲ — اجرا (بدون دیپلوی مجدد قرارداد)
۱. `npm install` و در `.env` کلید یک کیف پول تستی بگذار. هرگز کلید اصلی نگذار.
۲. نود فروشنده (روی سرور همیشه‌روشن): `node --env-file=.env script/provider-node.js`
   فایل `provider.config.json` داده هر دیتاست را مشخص می‌کند (id دیتاست ← فایل CSV).
۳. ربات keeper: `node --env-file=.env script/keeper.js`
۴. سایت: `npm run web` ← تب Decrypt با آدرس نود (پیش‌فرض http://localhost:8787).
۵. پایش نشت: `node script/leak-scan.js <requestId> <file>`
