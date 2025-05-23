// import 'package:delivery_note_app/providers/order_provider.dart';
// import 'package:delivery_note_app/widgets/widgets.dart';
// import 'package:flutter/material.dart';
// import 'package:provider/provider.dart';
//
// class PurchaseOrderDetailScreen extends StatelessWidget {
//   final String orderId;
//
//   const PurchaseOrderDetailScreen({super.key, required this.orderId});
//
//   @override
//   Widget build(BuildContext context) {
//     final order = Provider.of<OrderProvider>(context).getPurchaseOrderById(orderId);
//     final items = Provider.of<OrderProvider>(context).getItemsForOrder(orderId);
//
//     if (order == null) {
//       return Scaffold(
//         appBar: AppBar(),
//         body: const Center(child: Text('Order not found')),
//       );
//     }
//
//     return Scaffold(
//       appBar: AppBar(title: Text('Purchase Order #${order.id}')),
//       body: SingleChildScrollView(
//         padding: const EdgeInsets.all(16),
//         child: Column(
//           crossAxisAlignment: CrossAxisAlignment.start,
//           children: [
//             SummaryCard(
//               title: order.supplierName,
//               subtitle: 'Ref No: ${order.refNumber}',
//               details: [
//                 'PO Issue Date: ${order.issueDate.day}-${order.issueDate.month}-${order.issueDate.year}',
//               ],
//               status: order.isPending ? 'PENDING' : 'COMPLETED',
//               statusColor: order.isPending ? Colors.orange : Colors.green,
//             ),
//             const SizedBox(height: 24),
//             const Text('Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
//             const SizedBox(height: 8),
//             ...items.map((item) => ItemCard(item: item)),
//             const SizedBox(height: 16),
//             if (order.isPending)
//               Center(
//                 child: ElevatedButton(
//                   onPressed: () => Navigator.of(context).pushNamed('/add-lot'),
//                   child: const Text('Add Lot'),
//                 ),
//               ),
//           ],
//         ),
//       ),
//     );
//   }
// }