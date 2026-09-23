import { PGlite } from '@electric-sql/pglite'
import fs from 'fs'; import path from 'path'
const BASE = path.resolve(import.meta.dirname, '..')
const clean = s => s.replace(/^create extension.*$/gmi,'--')
  .replace(/^\s*(grant|revoke)\b[^;]*;/gmi,'--')
  .replace(/^\s*alter default privileges[^;]*;/gmi,'--')
const db = new PGlite()
await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema if not exists auth;
  create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text unique);
  create or replace function auth.uid() returns uuid language sql stable
    as $fn$ select nullif(current_setting('request.jwt.claims', true)::json->>'sub','')::uuid $fn$;
  create schema if not exists storage;
  create table if not exists storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
  create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
  create publication supabase_realtime;`)
for (const f of fs.readdirSync(path.join(BASE,'migrations')).filter(f=>f.endsWith('.sql')).sort())
  await db.exec(clean(fs.readFileSync(path.join(BASE,'migrations',f),'utf8')))
await db.exec(clean(fs.readFileSync(path.join(BASE,'seed.sql'),'utf8')))

// พนักงานหนึ่งคน เหมือนที่ seed_dev_staff.sql จะสร้างให้
const [{ id: branch }] = (await db.query(`select id from branches limit 1`)).rows
const [{ id: uid }] = (await db.query(`insert into auth.users(email) values ('owner@shabumood.local') returning id`)).rows
await db.query(`insert into profiles(id, branch_id, full_name, role) values ($1,$2,'เจ้าของร้าน','owner')`,[uid,branch])

console.log('--- รัน seed_demo.sql ---')
try { await db.exec(fs.readFileSync(path.join(BASE,'seed_demo.sql'),'utf8')) }
catch(e){ console.log('❌ ' + e.message.split('\n')[0]); if(e.cause?.where) console.log('   '+e.cause.where); process.exit(1) }
console.log('✅ รันผ่าน\n')

const q = async s => (await db.query(s)).rows
const show = async (label, sql) => console.log(label.padEnd(26) + JSON.stringify((await q(sql))[0] ?? {}))

console.log('=== แดชบอร์ดจะเห็นอะไร ===')
await show('ยอดขาย/บิล/หัว', `select to_char(sum(total_satang)/100.0,'FM999,999,990.00') บาท, count(*) บิล,
  sum(adult_count+child_count) คน from visits where status='closed'`)
console.log('เมนูขายดี:')
console.table(await q(`select name_snapshot เมนู, sum(quantity)::int จำนวน from order_items
  where status<>'cancelled' group by 1 order by 2 desc limit 6`))
console.log('วิธีชำระเงิน:')
console.table(await q(`select method วิธี, count(*)::int ครั้ง, to_char(sum(amount_satang)/100.0,'FM999,990.00') บาท
  from payments where status='succeeded' group by 1 order by 2 desc`))
console.log('ยอดตามชั่วโมง:')
console.table(await q(`select to_char(check_in_at,'HH24') ชม, count(*)::int โต๊ะ from visits
  where status='closed' group by 1 order by 1`))

console.log('\n=== ผังโต๊ะจะเห็นอะไร ===')
console.table(await q(`select t.table_number โต๊ะ, t.status สถานะโต๊ะ, v.status สถานะรอบ,
  coalesce(v.adult_count+v.child_count,0)::int คน, v.package_name_snapshot แพ็กเกจ,
  case when v.dining_deadline_at is null then '—'
       else greatest(0, extract(epoch from v.dining_deadline_at-now())/60)::int::text || ' นาที' end เหลือ
  from tables t left join visits v on v.table_id=t.id and v.status in ('open','awaiting_payment','paid')
  order by t.table_number`))

console.log('=== จอครัว / รอเสิร์ฟ ===')
console.table(await q(`select status สถานะ, count(*)::int จาน from order_items
  where status in ('pending','preparing','ready') group by 1 order by 1`))

console.log('=== คิว + เรียกพนักงาน + สมาชิก ===')
console.table(await q(`select ticket_number คิว, party_size คน, customer_name ชื่อ, status สถานะ
  from queue_tickets order by ticket_number`))
console.table(await q(`select type ประเภท, count(*)::int รายการ from service_requests where status='open' group by 1`))
console.table(await q(`select phone เบอร์, first_name ชื่อ, tier ระดับ, points_balance แต้ม, total_visits ครั้ง
  from customers order by points_balance desc`))

console.log('=== ตรวจความถูกต้อง ===')
const [chk] = await q(`select
  (select count(*) from visits where status='closed' and total_satang<=0) as บิลศูนย์,
  (select count(*) from visits v where status='closed'
     and total_satang <> coalesce((select sum(amount_satang) from payments p where p.visit_id=v.id and p.status='succeeded'),0)) as จ่ายไม่ตรงบิล,
  (select count(*) from bill_lines) as bill_lines,
  (select count(*) from order_status_history) as ประวัติสถานะ,
  (select count(*) from audit_logs) as audit,
  (select min_seconds_between_orders from restaurant_settings limit 1) as หน่วงเวลาคืนค่าแล้ว`)
console.log(JSON.stringify(chk, null, 2))
