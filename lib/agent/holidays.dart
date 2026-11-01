// Calendar data adapted from QQ Agent 0.4, Copyright (c) 2026 Kondius, MIT.
// The complete upstream notice is in docs/licenses/QQ-agent-MIT.txt.
import 'models.dart';

const _solar = {
  '01-01': '元旦',
  '02-14': '情人节',
  '03-08': '妇女节',
  '04-01': '愚人节',
  '05-01': '劳动节',
  '05-04': '青年节',
  '06-01': '儿童节',
  '09-10': '教师节',
  '10-01': '国庆节',
  '10-31': '万圣夜',
  '11-01': '万圣节',
  '12-24': '平安夜',
  '12-25': '圣诞节',
};
const _lunar = {
  '2024-02-10': '春节',
  '2024-02-24': '元宵节',
  '2024-04-04': '清明节',
  '2024-06-10': '端午节',
  '2024-08-10': '七夕',
  '2024-08-18': '中元节',
  '2024-09-17': '中秋节',
  '2024-10-11': '重阳节',
  '2025-01-28': '除夕',
  '2025-01-29': '春节',
  '2025-02-12': '元宵节',
  '2025-04-04': '清明节',
  '2025-05-31': '端午节',
  '2025-08-29': '七夕',
  '2025-09-06': '中元节',
  '2025-10-06': '中秋节',
  '2025-10-29': '重阳节',
  '2026-02-16': '除夕',
  '2026-02-17': '春节',
  '2026-03-03': '元宵节',
  '2026-04-05': '清明节',
  '2026-06-19': '端午节',
  '2026-08-19': '七夕',
  '2026-08-27': '中元节',
  '2026-09-25': '中秋节',
  '2026-10-18': '重阳节',
  '2027-02-05': '除夕',
  '2027-02-06': '春节',
  '2027-02-20': '元宵节',
  '2027-04-05': '清明节',
  '2027-06-09': '端午节',
  '2027-08-08': '七夕',
  '2027-09-15': '中秋节',
  '2027-10-08': '重阳节',
  '2028-01-25': '除夕',
  '2028-01-26': '春节',
  '2028-02-09': '元宵节',
  '2028-04-04': '清明节',
  '2028-05-28': '端午节',
  '2028-08-26': '七夕',
  '2028-09-03': '中元节',
  '2028-10-03': '中秋节',
  '2028-10-26': '重阳节',
  '2029-02-12': '除夕',
  '2029-02-13': '春节',
  '2029-02-27': '元宵节',
  '2029-04-04': '清明节',
  '2029-06-16': '端午节',
  '2029-08-16': '七夕',
  '2029-08-24': '中元节',
  '2029-09-22': '中秋节',
  '2029-10-16': '重阳节',
};

Json agentHolidays(String date, int days, {DateTime? now}) {
  final start = date.isEmpty ? now ?? DateTime.now() : DateTime.tryParse(date);
  if (start == null || days < 0 || days > 60) {
    throw const AgentException('日期应为YYYY-MM-DD，查询范围0–60天。');
  }
  String pad(int n) => n.toString().padLeft(2, '0');
  final values = <Json>[];
  for (var index = 0; index <= days; index++) {
    final day = DateTime(start.year, start.month, start.day + index);
    final md = '${pad(day.month)}-${pad(day.day)}', full = '${day.year}-$md';
    for (final row in [('solar', _solar[md]), ('lunar', _lunar[full])]) {
      if (row.$2 != null) {
        values.add({
          'name': row.$2,
          'type': row.$1,
          'date': full,
          'daysAway': index,
        });
      }
    }
  }
  return {
    'holidays': values,
    'lunarCalendarYears': [2024, 2029],
    'officialLeaveSchedule': false,
  };
}
