-- =====================================================
-- Al-Ahd-Platform : الجزء الثاني (نظام المستويات)
-- نسخة احتياطية لكل اللي اشتغل ونجح بـ Supabase بعد الجزء الأول.
-- الجزء الأول: al-ahd-setup.sql
-- =====================================================


-- =====================================================
-- 1) الجداول: مستويات البرنامج + تتبع الأعضاء + مواعيد الجامعات
-- =====================================================

create table if not exists public.program_levels (
  id uuid primary key default gen_random_uuid(),
  program_id uuid not null references public.cultural_programs(id) on delete cascade,
  level_number int not null check (level_number between 1 and 3),
  title text not null,
  duration_days int not null default 30 check (duration_days > 0),
  created_at timestamptz not null default now(),
  unique (program_id, level_number)
);

alter table public.materials
  add column if not exists level_id uuid references public.program_levels(id) on delete set null;

create table if not exists public.member_levels (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  program_id uuid not null references public.cultural_programs(id) on delete cascade,
  level_id uuid not null references public.program_levels(id) on delete cascade,
  started_at timestamptz not null default now(),
  due_at timestamptz not null,
  extended_until timestamptz,
  status text not null default 'in_progress'
    check (status in ('in_progress', 'passed', 'restarted')),
  passed_at timestamptz,
  recorded_by uuid,
  attempt int not null default 1,
  created_at timestamptz not null default now()
);

create unique index if not exists one_active_level_per_member
  on public.member_levels (user_id, program_id)
  where status = 'in_progress';

create table if not exists public.university_level_schedule (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id) on delete cascade,
  level_id uuid not null references public.program_levels(id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  unique (university_id, level_id),
  check (ends_on >= starts_on)
);

alter table public.program_levels enable row level security;
alter table public.member_levels enable row level security;
alter table public.university_level_schedule enable row level security;


-- =====================================================
-- 2) دوال مساعدة للسياسات
-- =====================================================

create or replace function public.is_in_my_university(target_user uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.user_id = target_user
      and p.university_id = public.get_my_university()
  )
$$;

create or replace function public.can_view_material(p_material uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.materials m
    left join public.program_levels pl on pl.id = m.level_id
    where m.id = p_material
      and m.is_published = true
      and (
        public.get_my_role_code() in ('admin', 'coordinator')
        or m.level_id is null
        or exists (
          select 1
          from public.member_levels ml
          join public.program_levels cur on cur.id = ml.level_id
          where ml.user_id = auth.uid()
            and ml.program_id = pl.program_id
            and ml.status in ('in_progress', 'passed')
            and ml.attempt = (
              select max(x.attempt) from public.member_levels x
              where x.user_id = auth.uid() and x.program_id = pl.program_id
            )
            and cur.level_number >= pl.level_number
        )
      )
  )
$$;

revoke execute on function public.can_view_material(uuid) from public, anon;
grant execute on function public.can_view_material(uuid) to authenticated;


-- =====================================================
-- 3) السياسات (RLS)
-- =====================================================

-- الأدمن بس بنزّل البرامج والمستويات والمواد
create policy "admin manages programs" on public.cultural_programs
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');

create policy "admin manages materials" on public.materials
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');

create policy "read levels" on public.program_levels
  for select to authenticated using (true);

create policy "admin manages levels" on public.program_levels
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');

-- العضو بشوف مواد مستواه بس (بدل السياسة القديمة)
drop policy if exists "Users can read published materials" on public.materials;

create policy "read materials by level" on public.materials
  for select to authenticated
  using (public.can_view_material(id));

-- تتبّع مستويات الأعضاء
create policy "read own levels" on public.member_levels
  for select to authenticated using (user_id = auth.uid());

create policy "coordinator reads university levels" on public.member_levels
  for select to authenticated
  using (public.get_my_role_code() = 'coordinator'
         and public.is_in_my_university(user_id));

create policy "admin manages member levels" on public.member_levels
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');

-- متابعة الإنجاز
create policy "coordinator reads university progress" on public.progress
  for select to authenticated
  using (public.get_my_role_code() = 'coordinator'
         and public.is_in_my_university(user_id));

create policy "admin reads all progress" on public.progress
  for select to authenticated
  using (public.get_my_role_code() = 'admin');

-- مواعيد المستويات لكل جامعة
create policy "read own university schedule" on public.university_level_schedule
  for select to authenticated
  using (university_id = public.get_my_university());

create policy "coordinator manages own schedule" on public.university_level_schedule
  for all to authenticated
  using (public.get_my_role_code() = 'coordinator'
         and university_id = public.get_my_university())
  with check (public.get_my_role_code() = 'coordinator'
              and university_id = public.get_my_university());

create policy "admin manages all schedules" on public.university_level_schedule
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');


-- =====================================================
-- 4) الأذونات على الجداول (مهمة: بدونها المستخدم المسجّل ما بقدر يقرأ)
--    الصفوف بتضل محمية بسياسات RLS
-- =====================================================

grant select, update on public.profiles to authenticated;

grant select on public.roles, public.universities,
                public.committees, public.committee_members to authenticated;

grant select, insert, update, delete on public.cultural_programs,
                public.program_levels, public.materials,
                public.university_level_schedule to authenticated;

grant select on public.member_levels to authenticated;

grant select, insert, update on public.progress to authenticated;


-- =====================================================
-- 5) دوال المستويات
-- =====================================================

create or replace function public.level_due_at(p_university uuid, p_level uuid)
returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select ((s.ends_on + time '23:59:59') at time zone 'Asia/Amman')
     from public.university_level_schedule s
     where s.university_id = p_university
       and s.level_id = p_level
       and s.ends_on >= current_date),
    now() + make_interval(days => (select duration_days from public.program_levels where id = p_level))
  )
$$;

create or replace function public.can_manage_member(target_user uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select case public.get_my_role_code()
    when 'admin' then true
    when 'coordinator' then exists (
      select 1 from public.profiles p
      join public.roles r on r.id = p.role_id
      where p.user_id = target_user
        and p.university_id = public.get_my_university()
        and r.code = 'member'
    )
    else false
  end
$$;

-- داخلية: إعادة العضو من أول البرنامج
create or replace function public.do_restart(p_user uuid, p_program uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_cur public.member_levels%rowtype;
  v_uni uuid;
  v_l1 uuid;
begin
  select * into v_cur from public.member_levels
   where user_id = p_user and program_id = p_program and status = 'in_progress';
  if not found then raise exception 'ما في مستوى فعّال لهالعضو'; end if;

  select university_id into v_uni from public.profiles where user_id = p_user;
  select id into v_l1 from public.program_levels
   where program_id = p_program and level_number = 1;
  if v_l1 is null then raise exception 'ما في مستوى 1 للبرنامج'; end if;

  update public.member_levels set status = 'restarted' where id = v_cur.id;

  insert into public.member_levels (user_id, program_id, level_id, due_at, attempt)
  values (p_user, p_program, v_l1, public.level_due_at(v_uni, v_l1), v_cur.attempt + 1);
end $$;

-- بدء العضو بالبرنامج (المستوى 1)
create or replace function public.start_member_program(p_user uuid, p_program uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uni uuid;
  v_l1 uuid;
begin
  if not public.can_manage_member(p_user) then raise exception 'ما عندك صلاحية'; end if;

  select university_id into v_uni from public.profiles where user_id = p_user;
  if v_uni is null then raise exception 'العضو مش مربوط بجامعة'; end if;

  if exists (select 1 from public.member_levels
             where user_id = p_user and program_id = p_program) then
    raise exception 'العضو بادئ هالبرنامج من قبل';
  end if;

  select id into v_l1 from public.program_levels
   where program_id = p_program and level_number = 1;
  if v_l1 is null then raise exception 'ما في مستوى 1 للبرنامج'; end if;

  insert into public.member_levels (user_id, program_id, level_id, due_at)
  values (p_user, p_program, v_l1, public.level_due_at(v_uni, v_l1));
end $$;

-- تسجيل نتيجة الاختبار: بترجع next_level أو program_completed أو not_passed
create or replace function public.record_test_result(p_user uuid, p_program uuid, p_passed boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_cur public.member_levels%rowtype;
  v_num int;
  v_next uuid;
  v_uni uuid;
begin
  if not public.can_manage_member(p_user) then raise exception 'ما عندك صلاحية'; end if;

  select * into v_cur from public.member_levels
   where user_id = p_user and program_id = p_program and status = 'in_progress';
  if not found then raise exception 'ما في مستوى فعّال لهالعضو'; end if;

  if not p_passed then return 'not_passed'; end if;

  if now() > coalesce(v_cur.extended_until, v_cur.due_at) then
    raise exception 'انتهى وقت المستوى، يلزم تمديد الوقت أو إعادة البرنامج';
  end if;

  update public.member_levels
     set status = 'passed', passed_at = now(), recorded_by = auth.uid()
   where id = v_cur.id;

  select level_number into v_num from public.program_levels where id = v_cur.level_id;
  select id into v_next from public.program_levels
   where program_id = p_program and level_number = v_num + 1;

  if v_next is null then return 'program_completed'; end if;

  select university_id into v_uni from public.profiles where user_id = p_user;
  insert into public.member_levels (user_id, program_id, level_id, due_at, attempt)
  values (p_user, p_program, v_next, public.level_due_at(v_uni, v_next), v_cur.attempt);

  return 'next_level';
end $$;

-- تمديد وقت عضو
create or replace function public.extend_member_time(p_user uuid, p_program uuid, p_until timestamptz)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_cur public.member_levels%rowtype;
begin
  if not public.can_manage_member(p_user) then raise exception 'ما عندك صلاحية'; end if;

  select * into v_cur from public.member_levels
   where user_id = p_user and program_id = p_program and status = 'in_progress';
  if not found then raise exception 'ما في مستوى فعّال لهالعضو'; end if;

  if p_until <= coalesce(v_cur.extended_until, v_cur.due_at) then
    raise exception 'موعد التمديد لازم يكون بعد الموعد الحالي';
  end if;

  update public.member_levels set extended_until = p_until where id = v_cur.id;
end $$;

-- إعادة عضو من أول البرنامج يدوياً
create or replace function public.restart_member_program(p_user uuid, p_program uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_member(p_user) then raise exception 'ما عندك صلاحية'; end if;
  perform public.do_restart(p_user, p_program);
end $$;

-- إعادة كل اللي خلص وقتهم الإضافي (المسؤول: جامعته، الأدمن: الكل، الجدولة: الكل)
create or replace function public.restart_expired_members()
returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
  v_role text := public.get_my_role_code();
begin
  if auth.uid() is not null and coalesce(v_role, '') not in ('admin', 'coordinator') then
    raise exception 'ما عندك صلاحية';
  end if;

  for r in
    select ml.user_id, ml.program_id
    from public.member_levels ml
    where ml.status = 'in_progress'
      and ml.extended_until is not null
      and ml.extended_until < now()
      and (auth.uid() is null or v_role = 'admin' or public.is_in_my_university(ml.user_id))
  loop
    perform public.do_restart(r.user_id, r.program_id);
    n := n + 1;
  end loop;

  return n;
end $$;

-- صلاحيات التنفيذ
revoke all on function public.do_restart(uuid, uuid) from public, anon, authenticated;

revoke execute on function public.level_due_at(uuid, uuid) from public, anon;
revoke execute on function public.can_manage_member(uuid) from public, anon;
revoke execute on function public.start_member_program(uuid, uuid) from public, anon;
revoke execute on function public.record_test_result(uuid, uuid, boolean) from public, anon;
revoke execute on function public.extend_member_time(uuid, uuid, timestamptz) from public, anon;
revoke execute on function public.restart_member_program(uuid, uuid) from public, anon;
revoke execute on function public.restart_expired_members() from public, anon;

grant execute on function public.level_due_at(uuid, uuid) to authenticated;
grant execute on function public.can_manage_member(uuid) to authenticated;
grant execute on function public.start_member_program(uuid, uuid) to authenticated;
grant execute on function public.record_test_result(uuid, uuid, boolean) to authenticated;
grant execute on function public.extend_member_time(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.restart_member_program(uuid, uuid) to authenticated;
grant execute on function public.restart_expired_members() to authenticated;


-- =====================================================
-- 6) الإعادة التلقائية كل ليلة (الساعة 12 بتوقيت الأردن = 21:00 UTC)
--    بتحتاج تفعيل إضافة pg_cron من Database > Extensions
-- =====================================================

select cron.schedule(
  'restart-expired-members',
  '0 21 * * *',
  $$ select public.restart_expired_members() $$
);


-- =====================================================
-- 7) حذف بيانات الاختبار (شغّليه لما تخلصوا تجارب الموقع)
--    ملاحظة: هاد حذف حقيقي، تأكدي إنك فعلاً بدك تحذفي الحسابات التجريبية
-- =====================================================

-- delete from public.member_levels where user_id in (
--   select user_id from public.profiles
--   where email in ('test-coordinator@example.com', 'test-member@example.com'));
-- delete from public.materials where title like '[تجريبي]%';
-- delete from public.cultural_programs where title like '[تجريبي]%';
-- delete from public.profiles
--   where email in ('test-coordinator@example.com', 'test-member@example.com');
-- delete from auth.users
--   where email in ('test-coordinator@example.com', 'test-member@example.com');
