import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/api_helper.dart';
import '../services/support_service.dart';
import '../theme/app_theme.dart';
import '../widgets/support_widgets.dart';
import 'support_ticket_form_page.dart';
import 'support_ticket_page.dart';

// =======================================================
// ช่วยเหลือและแจ้งปัญหา: คำร้องของฉัน + แจ้งปัญหาใหม่
// - ตัวกรอง ทั้งหมด / ยังไม่ปิด / ปิดแล้ว (เซิร์ฟเวอร์กรอง แบ่งหน้าละ 20)
// - เห็นได้เฉพาะคำร้องของตัวเอง
// =======================================================

class SupportCenterPage extends StatefulWidget {
  const SupportCenterPage({super.key});

  @override
  State<SupportCenterPage> createState() => _SupportCenterPageState();
}

class _SupportCenterPageState extends State<SupportCenterPage> {
  static const Map<String, String> filters = {
    'all': 'ทั้งหมด',
    'open': 'ยังไม่ปิด',
    'closed': 'ปิดแล้ว',
  };

  String filter = 'all';
  List<Map<String, dynamic>> tickets = [];
  int page = 1;
  bool hasMore = false;
  bool isLoading = true;
  bool isLoadingMore = false;
  String? loadError;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final String current = filter;

    try {
      final result = await SupportService.getTickets(filter: current);

      if (!mounted || current != filter) return;

      setState(() {
        tickets = parseTickets(result['tickets']);
        page = 1;
        hasMore = result['has_more'] == true;
        loadError = null;
      });
    } catch (e) {
      if (!mounted || current != filter) return;

      // มีรายการอยู่แล้ว → คงไว้ แจ้งเตือนแทน
      if (tickets.isEmpty) {
        setState(() => loadError = ApiHelper.messageOf(e));
      } else {
        showMessage(ApiHelper.messageOf(e));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || isLoading || isLoadingMore) return;

    final String current = filter;

    setState(() => isLoadingMore = true);

    try {
      final result = await SupportService.getTickets(
        filter: current,
        page: page + 1,
      );

      if (!mounted || current != filter) return;

      final Set<dynamic> known = tickets.map((t) => t['id']).toSet();

      setState(() {
        tickets.addAll(
          parseTickets(result['tickets'])
              .where((t) => !known.contains(t['id'])),
        );
        page++;
        hasMore = result['has_more'] == true;
      });
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isLoadingMore = false);
    }
  }

  List<Map<String, dynamic>> parseTickets(dynamic raw) {
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((t) => Map<String, dynamic>.from(t))
        .toList();
  }

  void changeFilter(String value) {
    if (value == filter) return;

    setState(() {
      filter = value;
      tickets = [];
      hasMore = false;
      isLoading = true;
      loadError = null;
    });

    load();
  }

  Future<void> openTicket(int id) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SupportTicketPage(ticketId: id)));

    if (mounted) await load();
  }

  Future<void> newTicket() async {
    final int? createdId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const SupportTicketFormPage()),
    );

    if (!mounted) return;

    if (createdId != null) {
      await openTicket(createdId);
    } else {
      await load();
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildTicket(Map<String, dynamic> ticket) {
    final int? id = (ticket['id'] as num?)?.toInt();
    final dynamic order = ticket['order'];

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: id == null ? null : () => openTicket(id),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: AppDecorations.cardBorder,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        ticket['code']?.toString() ?? '',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SupportStatusBadge(
                      status: ticket['status']?.toString(),
                      label: ticket['status_label']?.toString() ?? '',
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  ticket['subject']?.toString() ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    ticket['category_label']?.toString() ?? '',
                    if (order is Map) 'คำสั่งซื้อ ${order['code']}',
                    'อัปเดต ${formatDateTime(ticket['updated_at'])}',
                  ].join(' · '),
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildMessage(
    IconData icon,
    String title,
    String text, [
    Widget? action,
  ]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Column(
        children: [
          Icon(icon, size: 44, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 14), action],
        ],
      ),
    );
  }

  List<Widget> buildBody() {
    if (isLoading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 60),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (loadError != null) {
      return [
        buildMessage(
          Icons.cloud_off_rounded,
          'โหลดคำร้องไม่สำเร็จ',
          loadError!,
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(160, 44)),
            onPressed: () {
              setState(() {
                isLoading = true;
                loadError = null;
              });
              load();
            },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('ลองอีกครั้ง'),
          ),
        ),
      ];
    }

    if (tickets.isEmpty) {
      return [
        buildMessage(
          Icons.support_agent_rounded,
          filter == 'closed' ? 'ยังไม่มีเรื่องที่ปิดแล้ว' : 'ยังไม่มีคำร้อง',
          'มีปัญหาการใช้งาน บัญชี หรือคำสั่งซื้อ กด "แจ้งปัญหาใหม่" '
          'เพื่อส่งเรื่องให้ทีมงานตรวจสอบ',
        ),
      ];
    }

    return [
      ...tickets.map(buildTicket),
      if (isLoadingMore)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ช่วยเหลือและแจ้งปัญหา')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new_support_ticket',
        onPressed: newTicket,
        icon: const Icon(Icons.edit_note_rounded),
        label: const Text('แจ้งปัญหาใหม่'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 300) loadMore();
            return false;
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: [
              const SupportNote(
                icon: Icons.support_agent_rounded,
                text:
                    'ส่งเรื่องให้ทีมงานตรวจสอบได้ที่นี่ และติดตามคำตอบได้ในคำร้องของคุณ\n'
                    'ปัญหาคำสั่งซื้อหรือการคืนเงิน แจ้งจากหน้าคำสั่งซื้อ '
                    'ระบบจะแนบเลขคำสั่งซื้อให้อัตโนมัติ',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in filters.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: filter == entry.key,
                      onSelected: (_) => changeFilter(entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ...buildBody(),
            ],
          ),
        ),
      ),
    );
  }
}
