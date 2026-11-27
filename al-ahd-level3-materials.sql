-- =====================================================
-- Al-Ahd-Platform : إضافة مواد المستوى الثالث
-- شغّليه مرة وحدة من Supabase > SQL Editor
-- (الأدمن بس بضيف مواد، والـ SQL Editor بشتغل بصلاحية كاملة)
-- =====================================================

do $$
declare
  v_program uuid;
  v_level   uuid;
begin
  -- المستوى الثالث بالبرنامج (البرنامج موحّد، فبنجيب أول مستوى رقمه 3)
  select id, program_id into v_level, v_program
  from public.program_levels
  where level_number = 3
  order by created_at
  limit 1;

  if v_level is null then
    raise exception 'المستوى الثالث مش موجود. أنشئيه أول بـ createLevel أو من الجدول program_levels';
  end if;

  -- 1) المحاضرات الثلاث (فيديو)
  insert into public.materials
    (program_id, level_id, title, description, material_type, external_url, is_published)
  values
    (v_program, v_level, 'المحاضرة الأولى',
     'محاضرة المستوى الثالث: أسئلة الحياة اليومية ودورنا كطلاب.',
     'video', 'https://www.youtube.com/watch?v=INUKb-mPiK4', true),

    (v_program, v_level, 'المحاضرة الثانية',
     'محاضرة المستوى الثالث: أسئلة الحياة اليومية ودورنا كطلاب.',
     'video', 'https://www.youtube.com/watch?v=T9Ht2ivcFW4', true),

    (v_program, v_level, 'المحاضرة الثالثة',
     'محاضرة المستوى الثالث: أسئلة الحياة اليومية ودورنا كطلاب.',
     'video', 'https://www.youtube.com/watch?v=fsOfAY4WR3o', true);

  -- 2) المادة المقروءة (PDF)
  -- ⚠️ لسا مخفية (is_published = false) لحد ما تحطي رابط الملف الحقيقي
  -- بعد ما ترفعيه (مثلاً Google Drive بصلاحية "أي شخص معه الرابط")
  insert into public.materials
    (program_id, level_id, title, description, material_type, external_url, is_published)
  values
    (v_program, v_level, 'المادة المقروءة: طوفان الأقصى، سياقات ومآلات',
     'المادة المقروءة للمستوى الثالث.',
     'pdf', 'ضعي-رابط-الملف-هون', false);
end $$;


-- =====================================================
-- بعد ما ترفعي الـ PDF: حطي الرابط وفعّلي المادة
-- =====================================================
-- update public.materials
-- set external_url = 'https://drive.google.com/...',
--     is_published = true
-- where material_type = 'pdf'
--   and title like 'المادة المقروءة%';


-- =====================================================
-- فحص للتأكد (للقراءة فقط)
-- =====================================================
select m.title, m.material_type, m.is_published, l.level_number
from public.materials m
join public.program_levels l on l.id = m.level_id
where l.level_number = 3
order by m.created_at;
