import { Film, Download, Cloud, Box, Database, Server, Globe, type LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

// 카탈로그 app.json 의 icon 은 아래 맵의 키(lucide 아이콘 이름). 새 앱 추가 시 여기에 등록한다.
// (lucide 전체를 import * 하면 트리셰이킹이 깨져 번들이 커지므로 명시적 맵을 쓴다.)
const ICONS: Record<string, LucideIcon> = { Film, Download, Cloud, Box, Database, Server, Globe };

// color 는 아이콘 타일 배경색.
export function AppIcon({ name, color, size = 26 }: { name?: string; color?: string; size?: number }) {
  const Icon = (name && ICONS[name]) || Box;
  return (
    <div
      className="rounded-xl p-3 text-white flex items-center justify-center shrink-0"
      style={{ backgroundColor: color || '#64748b' }}
    >
      <Icon size={size} />
    </div>
  );
}

// 앱 타일 공통 셸: 아이콘 + 제목/배지 + 부제 + 하단 액션 영역(children).
export default function AppCard({
  icon, color, title, subtitle, badge, children,
}: {
  icon?: string;
  color?: string;
  title: string;
  subtitle?: string;
  badge?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="bg-white rounded-xl shadow-lg p-5 flex flex-col gap-4">
      <div className="flex items-start gap-3">
        <AppIcon name={icon} color={color} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h3 className="font-semibold truncate">{title}</h3>
            {badge}
          </div>
          {subtitle && <p className="text-sm text-gray-500 line-clamp-2 mt-0.5">{subtitle}</p>}
        </div>
      </div>
      {children && <div className="mt-auto flex items-center gap-2">{children}</div>}
    </div>
  );
}
