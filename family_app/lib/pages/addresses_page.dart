import 'package:flutter/material.dart';

import '../services/cart_service.dart';
import '../theme/app_theme.dart';
import 'address_form_page.dart';

// =======================================================
// ที่อยู่จัดส่งของฉัน
// เปิดจากหน้าสั่งซื้อ (selectedId) → แตะที่อยู่ = เลือกแล้วกลับ
// เปิดจากเมนู → จัดการที่อยู่ (เพิ่ม แก้ ลบ)
// =======================================================

class AddressesPage extends StatefulWidget {
  final int? selectedId;

  // true = แตะแล้วเลือกที่อยู่กลับไปหน้าสั่งซื้อ
  final bool picking;

  const AddressesPage({super.key, this.selectedId, this.picking = true});

  @override
  State<AddressesPage> createState() => _AddressesPageState();
}

class _AddressesPageState extends State<AddressesPage> {
  List<Map<String, dynamic>> addresses = [];
  bool isLoading = true;
  String? loadError;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loadError = null);

    try {
      final result = await CartService.getAddresses();

      if (!mounted) return;

      setState(() {
        if (result['status'] == true) {
          addresses = [
            for (final item in (result['addresses'] as List?) ?? const [])
              if (item is Map) Map<String, dynamic>.from(item),
          ];
        } else {
          loadError = result['message']?.toString() ?? 'โหลดไม่สำเร็จ';
        }
      });
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> openForm([Map<String, dynamic>? address]) async {
    final dynamic saved = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddressFormPage(address: address),
      ),
    );

    if (!mounted || saved == null) return;

    // เพิ่มที่อยู่ใหม่ตอนเลือก → ใช้ที่อยู่นั้นเลย
    if (widget.picking && address == null && saved is Map) {
      Navigator.of(context).pop(saved);
      return;
    }

    await load();
  }

  Future<void> remove(Map<String, dynamic> address) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ลบที่อยู่นี้?'),
        content: Text(address['full_address']?.toString() ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ไม่ลบ'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ลบ'),
          ),
        ],
      ),
    );

    final int? id = (address['id'] as num?)?.toInt();

    if (confirmed != true || id == null || !mounted) return;

    try {
      final result = await CartService.deleteAddress(id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result['message']?.toString() ?? '')),
      );

      await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Widget buildTile(Map<String, dynamic> address) {
    final bool selected = address['id'] == widget.selectedId;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.market.withValues(alpha: 0.06)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected ? AppColors.market : AppColors.border,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: widget.picking
            ? () => Navigator.of(context).pop(address)
            : () => openForm(address),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.location_on_outlined,
                color: AppColors.market,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${address['recipient_name']} · ${address['phone']}',
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (address['is_default'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.market.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              'ที่อยู่หลัก',
                              style: TextStyle(
                                color: AppColors.market,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      address['full_address']?.toString() ?? '',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'ตัวเลือก',
                onSelected: (value) {
                  if (value == 'edit') openForm(address);
                  if (value == 'delete') remove(address);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: Text('แก้ไข')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'ลบ',
                      style: TextStyle(color: AppColors.danger),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.picking ? 'เลือกที่อยู่จัดส่ง' : 'ที่อยู่จัดส่ง'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (loadError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        loadError!,
                        style: TextStyle(color: AppColors.danger),
                      ),
                    ),
                  if (addresses.isEmpty && loadError == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Text(
                        'ยังไม่มีที่อยู่จัดส่ง',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted),
                      ),
                    ),
                  for (final address in addresses) buildTile(address),
                  const SizedBox(height: 6),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.market,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () => openForm(),
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('เพิ่มที่อยู่ใหม่'),
                  ),
                ],
              ),
            ),
    );
  }
}
