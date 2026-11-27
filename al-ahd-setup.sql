-- =====================================================
-- Al-Ahd-Platform : ملف الإعداد الكامل (Supabase)
-- كل هالأكواد انعملت وانحفظت بقاعدة البيانات، هاد الملف نسخة احتياطية فقط.
-- =====================================================


-- =====================================================
-- 1) سياسات الحماية (RLS) وصلاحيات الأدوار
-- =====================================================

-- أعمدة إضافية
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists is_active boolean not null default true;

-- تفعيل الحماية
alter table public.profiles enable row level security;
alter table public.roles enable row level security;

-- حذف أي سياسات قديمة على الجدولين
do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in ('profiles', 'roles')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- دوال مساعدة
create or replace function public.get_my_role_code()
returns text
language sql stable security definer set search_path = public as $$
  select r.code
  from public.profiles p
  join public.roles r on r.id = p.role_id
  where p.user_id = auth.uid()
$$;

create or replace function public.get_my_university()
returns uuid
language sql stable security definer set search_path = public as $$
  select university_id from public.profiles where user_id = auth.uid()
$$;

-- جدول roles: أي مستخدم مسجّل بقدر يقرأ الأدوار
create policy "authenticated reads roles" on public.roles
  for select to authenticated using (true);

-- قراءة profiles
create policy "read own profile" on public.profiles
  for select to authenticated
  using (user_id = auth.uid());

create policy "admin reads all" on public.profiles
  for select to authenticated
  using (public.get_my_role_code() = 'admin');

create policy "coordinator reads own university" on public.profiles
  for select to authenticated
  using (
    public.get_my_role_code() = 'coordinator'
    and university_id = public.get_my_university()
  );

-- تعديل profiles
create policy "admin manages all" on public.profiles
  for all to authenticated
  using (public.get_my_role_code() = 'admin')
  with check (public.get_my_role_code() = 'admin');

create policy "coordinator updates own members" on public.profiles
  for update to authenticated
  using (
    public.get_my_role_code() = 'coordinator'
    and university_id = public.get_my_university()
    and role_id = (select id from public.roles where code = 'member')
  )
  with check (
    university_id = public.get_my_university()
    and role_id = (select id from public.roles where code = 'member')
  );


-- =====================================================
-- 2) جعل حساب الأدمن (الحساب انعمل أولاً من Authentication > Users)
-- =====================================================

update public.profiles
set
  role_id = (select id from public.roles where code = 'admin'),
  full_name = 'مدير المنصة',
  email = 'alahedunii@gmail.com',
  university_id = null
where user_id = '1278ce89-4fe4-4f7c-8d90-d502d1ea9047';


-- =====================================================
-- 3) فحوصات للتأكد (للقراءة فقط، ما بتغيّر شي)
-- =====================================================

-- الأدمن موجود؟ (المتوقع: صف فيه admin)
select p.full_name, p.email, r.code
from public.profiles p join public.roles r on r.id = p.role_id;

-- السياسات موجودة؟ (المتوقع: 6 صفوف)
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public' and tablename in ('profiles', 'roles')
order by tablename, policyname;

-- الحماية مفعّلة؟ (المتوقع: true للجدولين)
select relname, relrowsecurity
from pg_class
where relnamespace = 'public'::regnamespace and relname in ('profiles', 'roles');
