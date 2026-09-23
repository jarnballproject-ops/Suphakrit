-- ============================================================================
-- seed_demo.sql — ข้อมูลสาธิตสำหรับนำเสนอ
-- ----------------------------------------------------------------------------
-- สร้างภาพ "ร้านกำลังเปิดอยู่กลางวัน" ให้ทุกหน้าจอมีของจริงให้ดู:
--
--   แดชบอร์ดผู้จัดการ  ยอดขายวันนี้ เมนูขายดี กราฟรายชั่วโมง สัดส่วนแพ็กเกจและวิธีจ่าย
--   ผังโต๊ะ            โต๊ะเต็มบ้างว่างบ้าง มีโต๊ะที่เวลาใกล้หมด และโต๊ะรอเก็บ
--   จอครัว             ออเดอร์ค้างครบทั้งสามสถานะ รอรับ / กำลังทำ / พร้อมเสิร์ฟ
--   หน้ารอเสิร์ฟ        มีจานพร้อมเสิร์ฟจริง
--   หน้าเช็คบิล         มีโต๊ะที่กดเรียกเก็บเงินไว้แล้ว
--   คิวหน้าร้านและจอ TV มีคิวรอและคิวที่เรียกแล้ว
--   สมาชิก             มีลูกค้าที่มีแต้มสะสมให้ค้นด้วยเบอร์โทร
--
-- ทั้งหมดสร้างผ่าน RPC จริง (open_visit / place_order / create_payment / ...)
-- ไม่ได้ INSERT ตรงเข้าตาราง ข้อมูลที่ได้จึงผ่าน trigger ครบ — ยอดบิลถูกคำนวณจริง
-- bill_lines / order_status_history / audit_logs มีครบเหมือนใช้งานจริง
--
-- ต้องมีก่อน:
--   1) รัน migrations ครบทุกไฟล์ + seed.sql
--   2) มีบัญชีพนักงานอย่างน้อยหนึ่งคนใน profiles (รัน seed_dev_staff.sql)
--
-- วิธีรัน: Supabase Dashboard → SQL Editor → วางทั้งไฟล์ → Run
-- รันซ้ำได้ ข้อมูลจะเพิ่มทับเข้าไป (ดูสวิตช์ v_reset ด้านล่างถ้าอยากล้างก่อน)
-- ============================================================================

do $$
declare
  -- ── สวิตช์ ────────────────────────────────────────────────────────────────
  -- true = ล้างข้อมูลการใช้บริการเดิมทั้งหมดก่อนสร้างใหม่
  -- ⚠️ ลบ visits / orders / payments / คิว / แต้ม ทิ้งจริง ใช้เฉพาะกับฐานข้อมูลสาธิต
  --    ข้อมูลตั้งต้น (เมนู โต๊ะ แพ็กเกจ พนักงาน) ไม่ถูกแตะ
  v_reset boolean := false;

  v_branch   uuid;
  v_staff    uuid;
  v_std      uuid;
  v_prm      uuid;
  v_refill   uuid;

  -- เก็บค่าตั้งค่าเดิมไว้คืนตอนจบ
  v_old_gap  integer;
  v_old_open integer;
  v_old_qty  integer;

  v_visit    visits;
  v_order    orders;
  v_pay      payments;
  v_tbl      uuid;
  v_item     record;
  v_i        integer;
  v_made     integer := 0;
begin
  -- ── ตรวจของที่ต้องมีก่อน ────────────────────────────────────────────────
  select id into v_branch from branches order by created_at limit 1;
  if v_branch is null then
    raise exception 'ยังไม่มีสาขา — รัน seed.sql ก่อน' using errcode = 'no_data_found';
  end if;

  select id into v_staff from profiles
   where branch_id = v_branch and is_active and role in ('owner','manager','staff','cashier')
   order by case role when 'owner' then 1 when 'manager' then 2 else 3 end
   limit 1;
  if v_staff is null then
    raise exception
      'ยังไม่มีบัญชีพนักงานใน profiles — สร้างผู้ใช้ใน Authentication แล้วรัน seed_dev_staff.sql ก่อน'
      using errcode = 'no_data_found';
  end if;

  select id into v_std    from buffet_packages where branch_id = v_branch and code = 'standard';
  select id into v_prm    from buffet_packages where branch_id = v_branch and code = 'premium';
  select id into v_refill from add_ons         where branch_id = v_branch and code = 'drink_refill';

  -- ── สวมสิทธิ์พนักงาน ────────────────────────────────────────────────────
  -- RPC ทุกตัวตรวจ is_staff() ซึ่งอ่าน auth.uid() จาก JWT claims
  -- ใน SQL Editor ไม่มี JWT จึงต้องตั้งเอง — มีผลเฉพาะใน transaction นี้
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_staff, 'role', 'authenticated')::text,
                     true);

  -- ── ล้างของเดิม (ถ้าเปิดสวิตช์) ─────────────────────────────────────────
  if v_reset then
    delete from loyalty_transactions;
    delete from payments;
    delete from bill_lines;
    delete from order_status_history;
    delete from order_items;
    delete from orders;
    delete from service_requests;
    delete from visit_promotions;
    delete from visit_addons;
    delete from visit_devices;
    delete from visit_access_attempts;
    delete from queue_tickets;
    delete from visits;
    delete from customers;
    update tables set status = 'available';
    raise notice 'ล้างข้อมูลการใช้บริการเดิมแล้ว';
  end if;

  -- ── ผ่อนเพดานการสั่งชั่วคราว ────────────────────────────────────────────
  -- ของจริงมีหน่วงเวลาระหว่างรอบและจำกัดออเดอร์ค้าง ซึ่งจะบล็อกการ seed
  -- เก็บค่าเดิมไว้แล้วคืนตอนจบ
  select min_seconds_between_orders, max_unserved_orders_per_visit, max_qty_per_item
    into v_old_gap, v_old_open, v_old_qty
    from restaurant_settings where branch_id = v_branch;

  update restaurant_settings
     set min_seconds_between_orders = 0,
         max_unserved_orders_per_visit = 99,
         max_qty_per_item = 99
   where branch_id = v_branch;

  -- ── ลูกค้าสมาชิก ────────────────────────────────────────────────────────
  insert into customers (branch_id, phone, first_name, last_name, tier, marketing_consent)
  values
    (v_branch, '0812345678', 'ปวีณา',  'ศรีสุข',    'gold',   true),
    (v_branch, '0898887777', 'ธนกฤต',  'ใจดี',     'silver', true),
    (v_branch, '0865551234', 'มนัสนันท์','พงษ์ไพบูลย์','bronze', false),
    (v_branch, '0923334455', 'ศิริพร',  'วัฒนกุล',   'silver', true),
    (v_branch, '0877776666', 'อนุชา',  'รุ่งเรือง',   'bronze', true)
  on conflict (branch_id, phone) do nothing;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ส่วนที่ 1 — บิลที่ปิดไปแล้ววันนี้ ป้อนตัวเลขให้แดชบอร์ด
  -- ══════════════════════════════════════════════════════════════════════════
  -- เปิดโต๊ะ สั่ง เสิร์ฟ จ่าย ปิด แล้วค่อยย้อนเวลาให้กระจายทั้งวัน
  -- ต้องทำตามลำดับนี้เพราะ place_order ปฏิเสธออเดอร์ที่เลยเวลาหมดแล้ว

  for v_i in 1..14 loop
    select id into v_tbl from tables
     where branch_id = v_branch and is_active and status = 'available'
     order by table_number limit 1;
    exit when v_tbl is null;

    -- สลับแพ็กเกจให้สัดส่วนดูสมจริง ราว 40% เป็นพรีเมียม
    v_visit := open_visit(
      v_tbl,
      case when v_i % 5 in (0, 2) then v_prm else v_std end,
      2 + (v_i % 4),                                   -- ผู้ใหญ่ 2–5
      case when v_i % 4 = 0 then 1 else 0 end,         -- มีเด็กบ้าง
      case when v_i % 3 <> 0
           then jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 2 + (v_i % 4)))
           else '[]'::jsonb end,
      null,
      case v_i when 1 then '0812345678' when 4 then '0898887777'
               when 7 then '0923334455' when 11 then '0812345678' else null end
    );

    -- สั่งสองรอบ เมนูต่างกันไปตามรอบ เพื่อให้ "เมนูขายดี" มีลำดับจริง
    v_order := place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 1 + (v_i % 3)))
        from menu_items m
       where m.branch_id = v_branch
         and m.name_th in ('หมูสามชั้น','กุ้งขาว','เห็ดเข็มทอง','ผักกาดขาว','วุ้นเส้น')
    ));
    v_order := place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 1 + (v_i % 2)))
        from menu_items m
       where m.branch_id = v_branch
         and m.name_th in ('หมูสไลด์','ลูกชิ้นปลา','เต้าหู้ไข่','บัวลอย')
    ));

    -- โต๊ะพรีเมียมสั่งเมนูที่ล็อกไว้ได้ด้วย ทำให้เมนูขายดีไม่ซ้ำกันหมด
    if v_visit.package_id = v_prm then
      v_order := place_order(v_visit.id, (
        select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 1))
          from menu_items m
         where m.branch_id = v_branch and m.name_th in ('เนื้อริบอาย','ปลาแซลมอน')
      ));
    end if;

    -- บางโต๊ะสั่งเครื่องดื่มคิดเงินเพิ่ม ให้บิลไม่เท่ากันทุกใบ
    if v_i % 4 = 1 then
      v_order := place_order(v_visit.id, (
        select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 2))
          from menu_items m where m.branch_id = v_branch and m.name_th = 'เบียร์สิงห์'
      ));
    end if;

    -- เดินทุกจานไปจนเสิร์ฟครบ
    for v_item in
      select oi.id from order_items oi
        join orders o on o.id = oi.order_id
       where o.visit_id = v_visit.id and oi.status <> 'served'
    loop
      perform advance_order_item(v_item.id, 'preparing');
      perform advance_order_item(v_item.id, 'ready');
      perform advance_order_item(v_item.id, 'served');
    end loop;

    -- เช็คบิลแล้วจ่าย สลับวิธีจ่ายให้กราฟสัดส่วนมีของครบ
    v_visit := request_visit_bill(v_visit.id);
    v_pay := create_payment(
      v_visit.id,
      (array['cash','qr_promptpay','card','transfer'])[1 + (v_i % 4)]::payment_method,
      v_visit.total_satang,
      case when v_i % 4 = 1 then v_visit.total_satang + 10000 else null end
    );
    perform confirm_payment(v_pay.id);

    -- ย้อนเวลาการจ่าย "ก่อน" ปิดบิล — ห้ามสลับลำดับ
    -- trigger enforce_payment_not_exceeding_total() ยิงตอน UPDATE payments ด้วย
    -- ไม่ใช่แค่ตอน INSERT ถ้าปิดบิลไปก่อนแล้วค่อยแก้เวลา trigger จะอ่าน visit
    -- เจอสถานะ closed แล้วปฏิเสธทันที
    update payments
       set completed_at = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => 48 + (v_i % 10))
     where visit_id = v_visit.id;

    perform close_visit(v_visit.id);

    -- เว้นโต๊ะสุดท้ายไว้ไม่เก็บ ให้ผังโต๊ะมีสถานะ "รอทำความสะอาด" ให้เห็นด้วย
    -- ไม่งั้นทุกโต๊ะจะมีแค่ว่างกับกำลังใช้งาน ซึ่งไม่ตรงกับหน้างานจริง
    if v_i < 14 then
      perform mark_table_clean(v_tbl);
    end if;

    -- ย้อนเวลาให้กระจายตั้งแต่ 11 โมงถึงสองทุ่ม
    -- ทำหลังปิดบิลเพราะระหว่างทาง place_order ตรวจเวลาหมดอายุอยู่
    update visits
       set check_in_at   = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => (v_i * 7) % 60),
           billed_at     = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => 45 + (v_i % 10)),
           paid_at       = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => 48 + (v_i % 10)),
           check_out_at  = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => 50 + (v_i % 10))
     where id = v_visit.id;

    update order_items oi
       set created_at = date_trunc('day', now()) + make_interval(hours => 11 + (v_i % 9), mins => 10 + (v_i % 30))
      from orders o
     where o.id = oi.order_id and o.visit_id = v_visit.id;

    v_made := v_made + 1;
    v_tbl := null;
  end loop;

  raise notice 'สร้างบิลที่ปิดแล้ววันนี้ % ใบ', v_made;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ส่วนที่ 2 — โต๊ะที่กำลังใช้บริการอยู่ตอนนี้
  -- ══════════════════════════════════════════════════════════════════════════

  -- โต๊ะ 1 — เพิ่งนั่ง ออเดอร์แรกยังไม่มีใครรับ (จอครัวขึ้นใบใหม่)
  select id into v_tbl from tables
   where branch_id = v_branch and is_active and status = 'available' order by table_number limit 1;
  if v_tbl is not null then
    v_visit := open_visit(v_tbl, v_std, 2, 0,
      jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 2)), null, '0865551234');
    perform place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 2))
        from menu_items m where m.branch_id = v_branch
         and m.name_th in ('หมูสามชั้น','ผักกาดขาว','เห็ดเข็มทอง')));
  end if;

  -- โต๊ะ 2 — ครัวกำลังทำอยู่
  select id into v_tbl from tables
   where branch_id = v_branch and is_active and status = 'available' order by table_number limit 1;
  if v_tbl is not null then
    v_visit := open_visit(v_tbl, v_prm, 4, 0,
      jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 4)), null, '0812345678');
    perform place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 2))
        from menu_items m where m.branch_id = v_branch
         and m.name_th in ('เนื้อริบอาย','ปลาแซลมอน','กุ้งขาว','วุ้นเส้น')));
    for v_item in
      select oi.id from order_items oi join orders o on o.id = oi.order_id
       where o.visit_id = v_visit.id limit 3
    loop
      perform advance_order_item(v_item.id, 'preparing');
    end loop;
    -- ให้เข้าร้านมาสักพักแล้ว แถบเวลาบนผังโต๊ะจะได้ไม่เต็มเขียวหมดทุกโต๊ะ
    update visits set check_in_at = now() - interval '35 minutes' where id = v_visit.id;
  end if;

  -- โต๊ะ 3 — มีจานพร้อมเสิร์ฟค้างอยู่ (หน้ารอเสิร์ฟมีของ)
  select id into v_tbl from tables
   where branch_id = v_branch and is_active and status = 'available' order by table_number limit 1;
  if v_tbl is not null then
    v_visit := open_visit(v_tbl, v_std, 3, 1,
      jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 4)), null, null);
    perform place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 2))
        from menu_items m where m.branch_id = v_branch
         and m.name_th in ('หมูสไลด์','ลูกชิ้นปลา','ข้าวโพดอ่อน','ปอเปี๊ยะทอด')));
    for v_item in
      select oi.id from order_items oi join orders o on o.id = oi.order_id
       where o.visit_id = v_visit.id
    loop
      perform advance_order_item(v_item.id, 'preparing');
      perform advance_order_item(v_item.id, 'ready');
    end loop;
    update visits set check_in_at = now() - interval '20 minutes' where id = v_visit.id;
  end if;

  -- โต๊ะ 4 — นั่งมานาน เวลาใกล้หมด (ผังโต๊ะขึ้นแถบเหลือง/แดง) และกดเรียกพนักงาน
  select id into v_tbl from tables
   where branch_id = v_branch and is_active and status = 'available' order by table_number limit 1;
  if v_tbl is not null then
    v_visit := open_visit(v_tbl, v_std, 5, 0,
      jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 5)), null, '0877776666');
    perform place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 3))
        from menu_items m where m.branch_id = v_branch
         and m.name_th in ('หมูสามชั้น','กุ้งขาว','เห็ดนางฟ้า','บัวลอย')));
    for v_item in
      select oi.id from order_items oi join orders o on o.id = oi.order_id
       where o.visit_id = v_visit.id
    loop
      perform advance_order_item(v_item.id, 'preparing');
      perform advance_order_item(v_item.id, 'ready');
      perform advance_order_item(v_item.id, 'served');
    end loop;
    update visits
       set check_in_at = now() - interval '78 minutes',
           dining_deadline_at = now() + interval '12 minutes'
     where id = v_visit.id;

    insert into service_requests (visit_id, table_id, type, message)
    values (v_visit.id, v_tbl, 'refill_water', 'ขอน้ำจิ้มเพิ่มค่ะ');
  end if;

  -- โต๊ะ 5 — กดเช็คบิลแล้ว รอแคชเชียร์ (หน้าเช็คบิลมีโต๊ะให้กด)
  select id into v_tbl from tables
   where branch_id = v_branch and is_active and status = 'available' order by table_number limit 1;
  if v_tbl is not null then
    v_visit := open_visit(v_tbl, v_prm, 2, 0,
      jsonb_build_array(jsonb_build_object('add_on_id', v_refill, 'quantity', 2)), null, '0923334455');
    perform place_order(v_visit.id, (
      select jsonb_agg(jsonb_build_object('menu_item_id', m.id, 'quantity', 2))
        from menu_items m where m.branch_id = v_branch
         and m.name_th in ('เนื้อวากิว A5','หอยเชลล์','กุ้งแม่น้ำ','เบียร์สิงห์')));
    for v_item in
      select oi.id from order_items oi join orders o on o.id = oi.order_id
       where o.visit_id = v_visit.id
    loop
      perform advance_order_item(v_item.id, 'preparing');
      perform advance_order_item(v_item.id, 'ready');
      perform advance_order_item(v_item.id, 'served');
    end loop;
    update visits set check_in_at = now() - interval '62 minutes' where id = v_visit.id;
    v_visit := request_visit_bill(v_visit.id);

    insert into service_requests (visit_id, table_id, type, message)
    values (v_visit.id, v_tbl, 'request_bill', null);
  end if;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ส่วนที่ 3 — คิวหน้าร้าน
  -- ══════════════════════════════════════════════════════════════════════════
  perform issue_queue_ticket(2, 'คุณแพร',  '0811112222', null, 2, 0);
  perform issue_queue_ticket(4, 'คุณต้น',   '0822223333', null, 3, 1);
  perform issue_queue_ticket(6, 'คุณหนึ่ง',  '0833334444', 'ขอโต๊ะติดแอร์', 6, 0);
  perform issue_queue_ticket(3, 'คุณมิ้น',   '0844445555', null, 3, 0);
  perform issue_queue_ticket(5, 'คุณเอก',   '0855556666', null, 4, 1);

  -- เรียกไปแล้วหนึ่งคิว ให้จอ TV มีทั้งคิวที่เรียกและคิวที่รอ
  perform call_queue_ticket((
    select id from queue_tickets
     where branch_id = v_branch and status = 'waiting'
     order by ticket_number limit 1));

  -- ── คืนค่าตั้งค่าเดิม ────────────────────────────────────────────────────
  update restaurant_settings
     set min_seconds_between_orders = v_old_gap,
         max_unserved_orders_per_visit = v_old_open,
         max_qty_per_item = v_old_qty
   where branch_id = v_branch;

  raise notice 'สร้างข้อมูลสาธิตเสร็จแล้ว';
end;
$$;

-- ── สรุปสิ่งที่สร้างไว้ ──────────────────────────────────────────────────────
select 'บิลปิดแล้ววันนี้'  as รายการ, count(*)::text as จำนวน from visits where status = 'closed'
union all select 'โต๊ะกำลังใช้บริการ', count(*)::text from visits where status = 'open'
union all select 'รอชำระเงิน',        count(*)::text from visits where status = 'awaiting_payment'
union all select 'ออเดอร์ทั้งหมด',     count(*)::text from orders
union all select 'จานที่ยังไม่เสิร์ฟ',   count(*)::text from order_items where status in ('pending','preparing','ready')
union all select 'คิวที่ยังไม่ได้ที่นั่ง', count(*)::text from queue_tickets where status in ('waiting','called')
union all select 'ลูกค้าเรียกพนักงาน',  count(*)::text from service_requests where status = 'open'
union all select 'สมาชิก',             count(*)::text from customers
union all select 'ยอดขายวันนี้ (บาท)',
       to_char(coalesce(sum(total_satang), 0) / 100.0, 'FM999,999,990.00') from visits where status = 'closed';
