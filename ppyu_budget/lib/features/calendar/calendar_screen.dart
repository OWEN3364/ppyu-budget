import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:ppyu_budget/features/calendar/calendar_event_form_screen.dart' show CalendarEventFormScreen, calendarEventRepository;
import 'package:ppyu_budget/features/calendar/models/calendar_event.dart';
import 'package:ppyu_budget/features/calendar/recurrence.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  List<CalendarEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final events = await calendarEventRepository.list(widget.householdId);
      if (!mounted) return;
      setState(() {
        _events = events;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '일정을 불러오지 못했어요');
    }
  }

  // 보이는 달 앞뒤로 1개월씩 여유를 두고 발생을 계산 — 달력이 표시하는 grid가
  // 이전/다음 달의 며칠을 살짝 걸치기 때문 (다다음 주까지 넘어가는 경우 등).
  List<Occurrence> _occurrencesFor(DateTime day) {
    final events = _events;
    if (events == null) return [];
    final rangeStart = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
    final rangeEnd = DateTime(_focusedDay.year, _focusedDay.month + 2, 0, 23, 59, 59);
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day, 23, 59, 59);
    return events
        .expand((e) => expandOccurrences(e, rangeStart, rangeEnd))
        .where((o) => !o.start.isAfter(dayEnd) && !o.end.isBefore(dayStart))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final selectedDay = _selectedDay;
    return Scaffold(
      appBar: AppBar(title: const Text('캘린더')),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CalendarEventFormScreen(
              householdId: widget.householdId,
              initialDate: selectedDay ?? _focusedDay,
            ),
          ));
          _load();
        },
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (_events == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else ...[
            TableCalendar<Occurrence>(
              focusedDay: _focusedDay,
              firstDay: DateTime(2000),
              lastDay: DateTime(2100),
              selectedDayPredicate: (day) => isSameDay(selectedDay, day),
              eventLoader: _occurrencesFor,
              onDaySelected: (selected, focused) {
                setState(() {
                  _selectedDay = selected;
                  _focusedDay = focused;
                });
              },
              onPageChanged: (focused) => setState(() => _focusedDay = focused),
            ),
            Expanded(
              child: selectedDay == null
                  ? const Center(child: Text('날짜를 선택하면 일정이 보여요'))
                  : Builder(builder: (context) {
                      final occurrences = _occurrencesFor(selectedDay)
                        ..sort((a, b) => a.start.compareTo(b.start));
                      if (occurrences.isEmpty) {
                        return const Center(child: Text('이 날은 일정이 없어요'));
                      }
                      return ListView.builder(
                        itemCount: occurrences.length,
                        itemBuilder: (context, i) {
                          final occ = occurrences[i];
                          // 반복 일정의 어떤 발생을 탭했는지와 무관하게, 그
                          // 발생을 만들어낸 원본 이벤트를 찾아 상세 화면에
                          // 넘긴다 — 상세 화면은 발생이 아니라 규칙 자체를
                          // 다룬다.
                          final event = _events!.firstWhere(
                            (e) => expandOccurrences(e, occ.start, occ.start).isNotEmpty ||
                                (e.startAt == occ.start),
                          );
                          return ListTile(
                            title: Text(event.title),
                            subtitle: Text(event.allDay ? '종일' : '${occ.start.hour.toString().padLeft(2, '0')}:${occ.start.minute.toString().padLeft(2, '0')}'),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CalendarEventFormScreen(
                                  householdId: widget.householdId,
                                  existing: event,
                                ),
                              ));
                              _load();
                            },
                          );
                        },
                      );
                    }),
            ),
          ],
        ],
      ),
    );
  }
}
