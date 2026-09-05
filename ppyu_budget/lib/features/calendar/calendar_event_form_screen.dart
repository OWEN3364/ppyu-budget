import 'package:ppyu_budget/core/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/calendar/calendar_event_repository.dart';
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';

final calendarEventRepository = CalendarEventRepository(client: supabase);

const _weekdayLabels = [
  ('MO', '월'), ('TU', '화'), ('WE', '수'), ('TH', '목'), ('FR', '금'), ('SA', '토'), ('SU', '일'),
];

enum _Frequency { none, daily, weekly, monthly, yearly }

class CalendarEventFormScreen extends StatefulWidget {
  const CalendarEventFormScreen({
    super.key,
    required this.householdId,
    this.initialDate,
    this.existing,
  });

  final String householdId;
  final DateTime? initialDate;
  final CalendarEvent? existing;

  @override
  State<CalendarEventFormScreen> createState() => _CalendarEventFormScreenState();
}

class _CalendarEventFormScreenState extends State<CalendarEventFormScreen> {
  late final _titleController = TextEditingController(text: widget.existing?.title ?? '');
  late DateTime _date = widget.existing?.startAt ?? widget.initialDate ?? DateTime.now();
  late bool _allDay = widget.existing?.allDay ?? false;
  late TimeOfDay _startTime = TimeOfDay.fromDateTime(widget.existing?.startAt ?? DateTime.now());
  late TimeOfDay _endTime = TimeOfDay.fromDateTime(
    widget.existing?.endAt ?? DateTime.now().add(const Duration(hours: 1)),
  );
  late _Frequency _frequency = _parseFrequency(widget.existing?.recurrenceRule);
  late final Set<String> _selectedWeekdays = _parseWeekdays(widget.existing?.recurrenceRule);
  String? _error;
  bool _saving = false;

  static _Frequency _parseFrequency(String? rule) {
    if (rule == null) return _Frequency.none;
    if (rule == 'DAILY') return _Frequency.daily;
    if (rule.startsWith('WEEKLY:')) return _Frequency.weekly;
    if (rule == 'MONTHLY') return _Frequency.monthly;
    if (rule == 'YEARLY') return _Frequency.yearly;
    return _Frequency.none;
  }

  static Set<String> _parseWeekdays(String? rule) {
    if (rule == null || !rule.startsWith('WEEKLY:')) return {};
    return rule.substring(7).split(',').toSet();
  }

  String? get _recurrenceRule {
    switch (_frequency) {
      case _Frequency.none:
        return null;
      case _Frequency.daily:
        return 'DAILY';
      case _Frequency.weekly:
        return _selectedWeekdays.isEmpty ? null : 'WEEKLY:${_selectedWeekdays.join(',')}';
      case _Frequency.monthly:
        return 'MONTHLY';
      case _Frequency.yearly:
        return 'YEARLY';
    }
  }

  DateTime get _startAt => _allDay
      ? DateTime(_date.year, _date.month, _date.day)
      : DateTime(_date.year, _date.month, _date.day, _startTime.hour, _startTime.minute);

  DateTime get _endAt => _allDay
      ? DateTime(_date.year, _date.month, _date.day, 23, 59, 59)
      : DateTime(_date.year, _date.month, _date.day, _endTime.hour, _endTime.minute);

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '제목을 입력해주세요');
      return;
    }
    if (!_allDay && !_endAt.isAfter(_startAt)) {
      setState(() => _error = '종료 시각은 시작 시각보다 뒤여야 해요');
      return;
    }
    // Without this, _recurrenceRule silently returns null and "매주" is saved
    // as "no recurrence" with no feedback.
    if (_frequency == _Frequency.weekly && _selectedWeekdays.isEmpty) {
      setState(() => _error = '반복할 요일을 하나 이상 선택해주세요');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        final memberRow = await supabase
            .from('household_members')
            .select('id')
            .eq('household_id', widget.householdId)
            .eq('user_id', supabase.auth.currentUser!.id)
            .single();
        await calendarEventRepository.create(
          householdId: widget.householdId,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          allDay: _allDay,
          createdBy: memberRow['id'] as String,
          recurrenceRule: _recurrenceRule,
        );
      } else {
        await calendarEventRepository.update(
          id: existing.id,
          title: title,
          startAt: _startAt,
          endAt: _endAt,
          allDay: _allDay,
          recurrenceRule: _recurrenceRule,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정 저장에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final isRecurring = existing.recurrenceRule != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('일정 삭제'),
        content: Text(isRecurring ? '반복 일정 전체가 삭제돼요. 계속할까요?' : '이 일정을 삭제할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('삭제')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await calendarEventRepository.delete(existing.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정 삭제에 실패했어요');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(context: context, initialTime: isStart ? _startTime : _endTime);
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _startTime = picked;
      } else {
        _endTime = picked;
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? '일정 추가' : '일정 수정'),
        actions: [
          if (existing != null)
            IconButton(icon: const Icon(Icons.delete), onPressed: _saving ? null : _delete),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: '제목'),
            ),
            ListTile(
              title: const Text('날짜'),
              subtitle: Text('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
              onTap: _pickDate,
            ),
            SwitchListTile(
              title: const Text('종일'),
              value: _allDay,
              onChanged: (v) => setState(() => _allDay = v),
            ),
            if (!_allDay) ...[
              ListTile(
                title: const Text('시작 시각'),
                subtitle: Text(_startTime.format(context)),
                onTap: () => _pickTime(true),
              ),
              ListTile(
                title: const Text('종료 시각'),
                subtitle: Text(_endTime.format(context)),
                onTap: () => _pickTime(false),
              ),
            ],
            DropdownButton<_Frequency>(
              value: _frequency,
              items: const [
                DropdownMenuItem(value: _Frequency.none, child: Text('반복 없음')),
                DropdownMenuItem(value: _Frequency.daily, child: Text('매일')),
                DropdownMenuItem(value: _Frequency.weekly, child: Text('매주')),
                DropdownMenuItem(value: _Frequency.monthly, child: Text('매월')),
                DropdownMenuItem(value: _Frequency.yearly, child: Text('매년')),
              ],
              onChanged: (v) => setState(() => _frequency = v ?? _Frequency.none),
            ),
            if (_frequency == _Frequency.weekly)
              Wrap(
                spacing: 8,
                children: _weekdayLabels.map((entry) {
                  final (code, label) = entry;
                  final selected = _selectedWeekdays.contains(code);
                  return FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (v) => setState(() {
                      if (v) {
                        _selectedWeekdays.add(code);
                      } else {
                        _selectedWeekdays.remove(code);
                      }
                    }),
                  );
                }).toList(),
              ),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.error)),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}
