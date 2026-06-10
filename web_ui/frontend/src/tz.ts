// 시간대 목록/추측 유틸 — Setup(최초 설정)과 Settings(설정 변경)에서 공용.

// Intl.supportedValuesOf 미지원 브라우저용 주요 시간대 폴백
const TZ_FALLBACK = [
  'UTC',
  'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
  'America/Sao_Paulo', 'Europe/London', 'Europe/Paris', 'Europe/Berlin',
  'Europe/Madrid', 'Europe/Moscow', 'Africa/Cairo', 'Asia/Dubai', 'Asia/Kolkata',
  'Asia/Bangkok', 'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Singapore',
  'Asia/Seoul', 'Asia/Tokyo', 'Australia/Sydney', 'Pacific/Auckland',
];

function getTimezones(): string[] {
  try {
    const list = (Intl as any).supportedValuesOf?.('timeZone');
    if (Array.isArray(list) && list.length > 0) return list;
  } catch { /* fall through */ }
  return TZ_FALLBACK;
}

export function guessTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

export const TIMEZONES = getTimezones();
