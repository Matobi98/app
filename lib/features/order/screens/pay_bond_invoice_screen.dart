import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mostro/core/app_routes.dart';
import 'package:mostro/core/app_theme.dart';
import 'package:mostro/features/order/providers/trade_state_provider.dart';
import 'package:mostro/features/settings/providers/nwc_provider.dart';
import 'package:mostro/l10n/app_localizations.dart';
import 'package:mostro/src/rust/api/orders.dart' as orders_api;
import 'package:mostro/src/rust/api/types.dart' show OrderStatus;
import 'package:mostro/shared/widgets/nwc_payment_widget.dart';

/// Pay anti-abuse bond screen — Route `/pay_bond_invoice/:orderId`.
///
/// Shown when a taker takes an order on a bond-requiring node: the order sits
/// at [OrderStatus.waitingTakerBond] with the bond bolt11 in the trade's
/// `bondInvoice` slot. Once the daemon confirms the bond payment, this screen
/// forwards the taker to the next step (add-invoice for a buyer, pay-invoice
/// for a seller, else trade detail), mirroring [PayLightningInvoiceScreen].
class PayBondInvoiceScreen extends ConsumerStatefulWidget {
  const PayBondInvoiceScreen({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<PayBondInvoiceScreen> createState() =>
      _PayBondInvoiceScreenState();
}

class _PayBondInvoiceScreenState extends ConsumerState<PayBondInvoiceScreen> {
  bool _waiting = false;

  /// `true` when NWC is connected but payment failed → show QR fallback.
  bool _manualMode = false;

  /// One-shot guard so we don't navigate twice as further statuses stream in.
  bool _navigated = false;

  /// NWC success callback: just show the spinner — the actual navigation is
  /// driven by the [tradeStatusProvider] listener below, which waits for the
  /// daemon to confirm the bond HTLC and advance the order.
  void _onPaymentDetected() {
    if (!mounted) return;
    setState(() => _waiting = true);
  }

  /// Back out of the take while the bond is unpaid. Sends a real cancel so the
  /// daemon releases the bond (no slash) and returns the order to the book —
  /// unlike a bare pop, which would strand the order at WaitingTakerBond.
  Future<void> _confirmAndCancel() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cancelTradeDialogTitle),
        content: Text(l10n.cancelBondBackoutDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.noButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.yesCancelButtonLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await orders_api.cancelOrder(orderId: widget.orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.orderCancelledSuccess)),
      );
      context.go(AppRoute.home);
    } catch (e, st) {
      debugPrint('[PayBondInvoiceScreen] cancelOrder error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cancelRequestFailed)),
      );
    }
  }

  Widget _waitingIndicator(AppColors? colors, Color green,
          AppLocalizations l10n) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: green),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.waitingForPaymentConfirmation,
            style: TextStyle(color: colors?.textSecondary),
          ),
        ],
      );

  Widget _cancelButton(AppColors? colors, AppLocalizations l10n) {
    final red = colors?.destructiveRed ?? const Color(0xFFD84D4D);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _confirmAndCancel,
        style: OutlinedButton.styleFrom(
          foregroundColor: red,
          side: BorderSide(color: red),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
        ),
        child: Text(l10n.cancel),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<AppColors>();
    final green = colors?.mostroGreen ?? const Color(0xFF8CC63F);
    final cardBg = colors?.backgroundCard ?? const Color(0xFF1E2230);
    final l10n = AppLocalizations.of(context);

    final isWalletConnected = ref.watch(isWalletConnectedProvider);
    final tradeAsync = ref.watch(tradeBondInfoProvider(widget.orderId));

    // Forward the taker to the matching next step once the bond is paid;
    // stay put while the order is still at waitingTakerBond/pending.
    ref.listen<AsyncValue<OrderStatus>>(
      tradeStatusProvider(widget.orderId),
      (prev, next) {
        final status = next.valueOrNull;
        if (status == null || _navigated || !mounted) return;
        switch (status) {
          case OrderStatus.waitingTakerBond:
          case OrderStatus.pending:
            break;
          case OrderStatus.waitingBuyerInvoice: // buyer taker
            _navigated = true;
            context.pushReplacement(AppRoute.addInvoicePath(widget.orderId));
            break;
          case OrderStatus.waitingPayment: // seller taker
            _navigated = true;
            context.pushReplacement(AppRoute.payInvoicePath(widget.orderId));
            break;
          // Already progressed past the invoice step.
          case OrderStatus.active:
          case OrderStatus.fiatSent:
          case OrderStatus.inProgress:
          case OrderStatus.settledHoldInvoice:
          case OrderStatus.success:
          case OrderStatus.dispute:
            _navigated = true;
            context.go(AppRoute.tradeDetailPath(widget.orderId));
            break;
          case OrderStatus.canceled:
          case OrderStatus.cooperativelyCanceled:
          case OrderStatus.canceledByAdmin:
          case OrderStatus.expired:
            _navigated = true;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.orderNoLongerActive)),
            );
            context.go(AppRoute.home);
            break;
          default:
            break;
        }
      },
    );

    return tradeAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: Text(l10n.payBondInvoiceTitle)),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) {
        debugPrint('[PayBondInvoiceScreen] load error: $e\n$st');
        return Scaffold(
          appBar: AppBar(title: Text(l10n.payBondInvoiceTitle)),
          body: Center(child: Text(l10n.tradeLoadError)),
        );
      },
      data: (trade) {
        final invoice = trade?.bondInvoice ?? '';
        final amountSats = trade?.bondAmountSats?.toInt() ?? 0;

        if (invoice.isEmpty) {
          // Bond invoice not yet available — waiting for the Mostro daemon.
          return Scaffold(
            appBar: AppBar(title: Text(l10n.payBondInvoiceTitle)),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: green),
                  const SizedBox(height: 16),
                  Text(
                    l10n.tradeWaitingForBondInvoice,
                    style: TextStyle(color: colors?.textSecondary),
                  ),
                ],
              ),
            ),
          );
        }

        // NWC wallet connected and payment hasn't failed yet: pay from it.
        if (isWalletConnected && !_manualMode) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.payBondInvoiceTitle)),
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  const Spacer(),
                  if (_waiting)
                    _waitingIndicator(colors, green, l10n)
                  else
                    NwcPaymentWidget(
                      bolt11: invoice,
                      amountSats: amountSats,
                      onPaymentSuccess: _onPaymentDetected,
                      onFallbackToManual: () =>
                          setState(() => _manualMode = true),
                    ),
                  const Spacer(),
                  if (!_waiting) _cancelButton(colors, l10n),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text(l10n.payBondInvoiceTitle)),
          body: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.shield_outlined, color: green, size: 24),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                l10n.payBondInvoiceInstruction,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                        if (amountSats > 0) ...[
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            l10n.payInvoiceAmount(amountSats.toString()),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),

                        // QR Code
                        Expanded(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.card),
                              ),
                              child: QrImageView(
                                data: invoice,
                                size: 200,
                                backgroundColor: Colors.white,
                                semanticsLabel: l10n.bondInvoiceQrLabel,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),

                        // Pay with external Lightning wallet (lightning: URI)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () async {
                              final uri = Uri.parse('lightning:$invoice');
                              bool launched = false;
                              try {
                                launched = await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              } catch (_) {
                                launched = false;
                              }
                              if (!launched && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.noLightningWalletFound),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.bolt, size: 18),
                            label: Text(l10n.payWithLightningWallet),
                            style: FilledButton.styleFrom(
                              backgroundColor: green,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.button),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),

                        // Copy + Share buttons
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: invoice),
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.invoiceCopied),
                                      duration: const Duration(seconds: 1),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy, size: 16),
                                label: Text(l10n.copyButtonLabel),
                                style: FilledButton.styleFrom(
                                  backgroundColor: green,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.button),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  try {
                                    await SharePlus.instance
                                        .share(ShareParams(text: invoice));
                                  } catch (e, st) {
                                    debugPrint(
                                      '[PayBondInvoiceScreen] share failed: $e\n$st',
                                    );
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(l10n.shareFailed)),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.share, size: 16),
                                label: Text(l10n.shareButtonLabel),
                                style: FilledButton.styleFrom(
                                  backgroundColor: green,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.button),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                if (_waiting)
                  _waitingIndicator(colors, green, l10n)
                else
                  _cancelButton(colors, l10n),
              ],
            ),
          ),
        );
      },
    );
  }
}
