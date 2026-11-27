// =====================================================
// Al-Ahd-Platform : ملف الربط مع Supabase (للمطوّر)
// كل دالة هون بتنادي قاعدة البيانات، والأمان بيتأكد منه Supabase نفسه.
// يعني حتى لو الصفحة غلطت، المسؤول ما بشوف جامعة ثانية.
// =====================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// من Supabase: Project Settings ← API
const SUPABASE_URL = 'https://myfsnxdpxthterfuqbzr.supabase.co'
const SUPABASE_ANON_KEY = 'sb_publishable_T4n9tP9x-PkhTsiDgf7eFg_26Q28kR_' // anon / publishable فقط. ممنوع service_role

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

// رسالة الخطأ من قاعدة البيانات بتكون جاهزة للعرض (error.message)
async function run(query) {
  const { data, error } = await query
  if (error) throw new Error(error.message)
  return data
}

// ---------- الدخول ----------
export async function signIn(email, password) {
  return run(supabase.auth.signInWithPassword({ email, password }))
}

export async function signOut() {
  await supabase.auth.signOut()
}

// ---------- الأدوار (داخلي) ----------
let rolesCache = null
async function getRoles() {
  if (!rolesCache) rolesCache = await run(supabase.from('roles').select('id, code, name'))
  return rolesCache
}

// ---------- بياناتي ----------
// roleCode: 'admin' أو 'coordinator' أو 'member'
export async function getMyProfile() {
  const { data: { user } } = await supabase.auth.getUser()
  const me = await run(
    supabase.from('profiles')
      .select('id, user_id, full_name, email, university_id, role_id, is_active')
      .eq('user_id', user.id).single()
  )
  const roles = await getRoles()
  return { ...me, roleCode: roles.find(r => r.id === me.role_id)?.code }
}

// =====================================================
// الأعضاء
// =====================================================

// المسؤول بشوف جامعته بس، والأدمن بشوف الكل (الأمان تلقائي)
export async function listMembers() {
  const roles = await getRoles()
  const rows = await run(
    supabase.from('profiles')
      .select('id, user_id, full_name, email, university_id, role_id, is_active, created_at')
      .order('created_at', { ascending: false })
  )
  return rows.map(p => ({ ...p, roleCode: roles.find(r => r.id === p.role_id)?.code }))
}

// المسؤول: full_name, email, password فقط (الجامعة بتنربط تلقائياً)
// الأدمن: كمان university_id و role ('coordinator' أو 'member')
export async function addMember({ full_name, email, password, university_id, role }) {
  const { data, error } = await supabase.functions.invoke('create-member', {
    body: { full_name, email, password, university_id, role },
  })
  if (error) {
    let msg = error.message
    try { msg = (await error.context.json()).error || msg } catch {}
    throw new Error(msg)
  }
  return data
}

export async function updateMember(id, { full_name, is_active }) {
  return run(supabase.from('profiles').update({ full_name, is_active }).eq('id', id))
}

export async function listUniversities() {
  return run(supabase.from('universities').select('id, name, name_ar'))
}

// =====================================================
// البرنامج الثقافي (القراءة: الكل | الإضافة والتعديل: الأدمن فقط)
// =====================================================

export async function listPrograms() {
  return run(supabase.from('cultural_programs').select('*').order('created_at'))
}

export async function listLevels(programId) {
  return run(
    supabase.from('program_levels').select('*')
      .eq('program_id', programId).order('level_number')
  )
}

// العضو بشوف مواد مستواه بس، والمسؤول والأدمن بشوفوا الكل (الفلترة تلقائية)
// material_type المسموح: 'video' أو 'pdf' أو 'link'
export async function listMaterials(programId, levelId) {
  let q = supabase.from('materials').select('*').order('created_at')
  if (programId) q = q.eq('program_id', programId)
  if (levelId) q = q.eq('level_id', levelId)
  return run(q)
}

// ---- الأدمن فقط ----
export async function createProgram({ title, description, start_date, end_date, is_published }) {
  return run(
    supabase.from('cultural_programs')
      .insert({ title, description, start_date, end_date, is_published })
      .select().single()
  )
}

export async function createLevel({ program_id, level_number, title }) {
  return run(
    supabase.from('program_levels')
      .insert({ program_id, level_number, title })
      .select().single()
  )
}

export async function addMaterial({
  program_id, level_id, title, description,
  material_type, external_url, file_path, is_published,
}) {
  return run(
    supabase.from('materials')
      .insert({ program_id, level_id, title, description, material_type, external_url, file_path, is_published })
      .select().single()
  )
}

// =====================================================
// مواعيد المستويات (كل جامعة إلها مواعيدها)
// =====================================================

// العضو والمسؤول بشوفوا مواعيد جامعتهم، والأدمن بشوف الكل
export async function getSchedule() {
  return run(supabase.from('university_level_schedule').select('*'))
}

// المسؤول بحدد مواعيد جامعته. الأدمن لازم يبعت university_id.
// starts_on و ends_on بصيغة 'YYYY-MM-DD'
export async function saveSchedule({ level_id, starts_on, ends_on, university_id }) {
  const me = await getMyProfile()
  return run(
    supabase.from('university_level_schedule')
      .upsert(
        { university_id: university_id ?? me.university_id, level_id, starts_on, ends_on, updated_by: me.user_id },
        { onConflict: 'university_id,level_id' }
      )
      .select().single()
  )
}

// =====================================================
// مستويات الأعضاء
// =====================================================

// مستوى العضو الحالي ومواعيده (للعضو: مستواه، وللمسؤول: أعضاء جامعته)
// الحقول: level_id, due_at, extended_until, status, attempt
// status: 'in_progress' (حالي) أو 'passed' أو 'restarted' (سجل قديم)
export async function listMemberLevels(programId) {
  return run(
    supabase.from('member_levels')
      .select('*, program_levels(level_number, title)')
      .eq('program_id', programId)
      .order('created_at', { ascending: false })
  )
}

// أعضاء + مستواهم الحالي بنداء واحد (للمسؤول والأدمن)
export async function listMembersWithLevel(programId) {
  const [members, levels] = await Promise.all([
    listMembers(),
    run(
      supabase.from('member_levels')
        .select('*, program_levels(level_number, title)')
        .eq('program_id', programId).eq('status', 'in_progress')
    ),
  ])
  const byUser = new Map(levels.map(l => [l.user_id, l]))
  return members
    .filter(m => m.roleCode === 'member')
    .map(m => ({ ...m, currentLevel: byUser.get(m.user_id) ?? null }))
}

// ---- أزرار المسؤول والأدمن (كلها بتتحقق من الصلاحية بقاعدة البيانات) ----

// بدء العضو بالمستوى 1
export async function startMemberProgram(userId, programId) {
  return run(supabase.rpc('start_member_program', { p_user: userId, p_program: programId }))
}

// تسجيل نتيجة الاختبار. بترجع: 'next_level' أو 'program_completed' أو 'not_passed'
export async function recordTestResult(userId, programId, passed) {
  return run(supabase.rpc('record_test_result', { p_user: userId, p_program: programId, p_passed: passed }))
}

// تمديد الوقت. until: تاريخ ووقت ISO مثل '2026-12-10T23:59:00Z'
export async function extendMemberTime(userId, programId, until) {
  return run(supabase.rpc('extend_member_time', { p_user: userId, p_program: programId, p_until: until }))
}

// إعادة عضو من أول البرنامج يدوياً
export async function restartMemberProgram(userId, programId) {
  return run(supabase.rpc('restart_member_program', { p_user: userId, p_program: programId }))
}

// إعادة كل اللي خلص وقتهم الإضافي (بترجع عددهم). النظام بعملها لحاله كل ليلة كمان.
export async function restartExpiredMembers() {
  return run(supabase.rpc('restart_expired_members'))
}
