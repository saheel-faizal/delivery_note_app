import 'dart:async';
import 'dart:convert';

import 'package:delivery_note_app/models/delivery_note_details.dart';
import 'package:delivery_note_app/models/delivery_note_header.dart';
import 'package:delivery_note_app/models/inventory_detail_serialno.dart';
import 'package:delivery_note_app/utils/app_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_datawedge/flutter_datawedge.dart';
import 'package:intl/intl.dart';
import 'package:mssql_connection/mssql_connection.dart';
import 'package:delivery_note_app/models/sales_order_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OrderProvider with ChangeNotifier {
  final MssqlConnection _sqlConnection = MssqlConnection.getInstance();
  List<SalesOrder> _salesOrders = [];
  bool _isLoading = false;
  String? _error;

  List<SalesOrder> get salesOrders => _salesOrders;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> fetchSalesOrders() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final result = await _sqlConnection.getData("""
      SELECT * FROM VW_DM_SODetails
      ORDER BY SoNumber, ItemCode
      """);

      final data = jsonDecode(result) as List;

      // Create a map to group orders by SO number
      final ordersMap = <String, SalesOrder>{};

      for (var json in data) {
        final soNumber = json['SoNumber'].toString();

        if (!ordersMap.containsKey(soNumber)) {
          // Create new order with first item
          ordersMap[soNumber] = SalesOrder.fromJson(json);
        } else {
          // Add item to existing order
          ordersMap[soNumber]!.addItem(json);
        }
      }

      // Convert map values to list
      _salesOrders = ordersMap.values.toList();
    } catch (e) {
      _error = 'Failed to fetch orders: ${e.toString()}';
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  Future<List<SalesOrder>> getSalesOrdersByLocation(String locationCode) async {
    try {
      final result = await _sqlConnection.getData("""
        SELECT * FROM VW_DM_SODetails 
        WHERE LocCode = '$locationCode'
        ORDER BY SODate DESC
      """);

      final data = jsonDecode(result) as List;
      return data.map((json) => SalesOrder.fromJson(json)).toList();
    } catch (e) {
      throw Exception('Failed to fetch orders: ${e.toString()}');
    }
  }

  // Validate stock and quantities before proceeding
  bool isValidForPosting = true;
  String validationMessage = '';

  Future<void> postDeliveryNote(BuildContext context, String soNumber) async {
    validationMessage = "";
    isValidForPosting = true;
    final order = getSalesOrderById(soNumber);
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final String companyCode = prefs.getString('companyCode') ?? "";
    final String username = prefs.getString("username") ?? "";
    if (order == null) {
      print('Order not found for SO: $soNumber');
      AppAlerts.appToast(message: "Order not found for SO: $soNumber");
      return;
    }

    // Validate each item's stock and quantities
    for (var item in order.items) {
      // Skip validation for non-inventory items
      if (!item.nonInventory) {
        // Check if stock is sufficient
        if (item.stockQty < item.qtyIssued) {
          isValidForPosting = false;
          validationMessage +=
              'Insufficient stock for ${item.itemCode} - ${item.itemName}. Available: ${item.stockQty}, Issued: ${item.qtyIssued}\n';
        }
      }

      // Check if qty issued is <= qty ordered (but not greater)
      if (item.qtyIssued > item.qtyOrdered) {
        isValidForPosting = false;
        validationMessage +=
        'Quantity issued cannot exceed quantity ordered for ${item.itemCode} - ${item.itemName}. Issued: ${item.qtyIssued}, Ordered: ${item.qtyOrdered}\n';
      }

      // Check serial numbers for serialized items
      if (item.serialYN && (item.qtyIssued > 0)) {
        if (item.serials.length != item.qtyIssued) {
          isValidForPosting = false;
          validationMessage +=
              'Serial numbers required for ${item.itemCode} - ${item.itemName}. Expected: ${item.qtyOrdered}, Provided: ${item.serials.length}\n';
        }
      }
    }

    // If validation fails, show error message and return
    if (!isValidForPosting) {
      notifyListeners();
      AppAlerts.appToast(
          message:
              "Delivery note validation failed, please check the log in above");
      // You could also show a more detailed dialog here
      return;
    }

    String deliveryNoteNumber = "DN00001";

    try {
      // 1. Create DeliveryNoteHeader
      final deliveryNoteHeader = DeliveryNoteHeader(
        cmpyCode: order.companyCode,
        dnNumber: deliveryNoteNumber, // Temporary number
        locCode: order.locationCode,
        dates: DateTime.now(),
        customerCode: order.customerCode,
        salesmanCode: order.salesmanCode,
        soNumber: order.soNumber,
        refNo: order.refNo, // will later entered manually
        status: 'O', // Open status
        invStat: 'N', // Not invoiced
        discount: 0, // from SO
        curCode: 'AED', // from SO
        exRate: 1, // from SO
        dnType: 'D', // Delivery type
        qty: order.items.length, // from SO
        dTime: TimeOfDay.now(), // time of day
        loginUser: username,
        creditLimitAmount: 0, // auto
        outstandingBalance: 0, // auto
        grossAmount: 0, // auto calculated maybe from frontend
        narration: '', // manually add later
        commissionYN: 'N', // from SO
        supplier: '', // from SO
        dyType: 'D', // Default D
      );

      // Post header
      final headerQuery = '''
INSERT INTO DNoteHeader (
  Cmpycode, DnNumber, LocCode, Dates, CustomerCode, SalesmanCode, 
  SoNumber, RefNo, Status, InvStat, Discount, CurCode, ExRate, 
  DnType, Qty, DTime, LoginUser, CreditLimitAmount, OutstandingBalance, 
  GrossAmount, Narration, CommissionYN, Supplier, DYType
) VALUES (
  '${deliveryNoteHeader.cmpyCode}', 
  '${deliveryNoteHeader.dnNumber}', 
  '${deliveryNoteHeader.locCode}', 
  CONVERT(DATETIME, '${DateFormat('yyyy-MM-dd').format(deliveryNoteHeader.dates)}', 120), 
  '${deliveryNoteHeader.customerCode}', 
  '${deliveryNoteHeader.salesmanCode}',
  '${deliveryNoteHeader.soNumber}', 
  '${deliveryNoteHeader.refNo}', 
  '${deliveryNoteHeader.status}', 
  '${deliveryNoteHeader.invStat}', 
  ${deliveryNoteHeader.discount}, 
  '${deliveryNoteHeader.curCode}', 
  ${deliveryNoteHeader.exRate},
  '${deliveryNoteHeader.dnType}', 
  ${deliveryNoteHeader.qty}, 
  CONVERT(TIME, '${deliveryNoteHeader.dTime.hour.toString().padLeft(2, '0')}:${deliveryNoteHeader.dTime.minute.toString().padLeft(2, '0')}:00'), 
  '${deliveryNoteHeader.loginUser}', 
  ${deliveryNoteHeader.creditLimitAmount}, 
  ${deliveryNoteHeader.outstandingBalance},
  ${deliveryNoteHeader.grossAmount}, 
  '${deliveryNoteHeader.narration}', 
  '${deliveryNoteHeader.commissionYN}', 
  '${deliveryNoteHeader.supplier}', 
  '${deliveryNoteHeader.dyType}'
)
''';

      print('Posting delivery note header...');
      await _sqlConnection.writeData(headerQuery);
      print(
          'Header posted successfully with DN: ${deliveryNoteHeader.dnNumber}');

      // 2. Create and post DeliveryNoteDetails for each item
      for (var item in order.items) {
        final detail = DeliveryNoteDetail(
          cmpyCode: order.companyCode,
          dnNumber: deliveryNoteHeader.dnNumber,
          locCode: order.locationCode,
          sno: order.items.indexOf(item) + 1,
          itemCode: item.itemCode,
          barcode: null,
          description: item.itemName,
          unit: item.unit,
          qtyOrdered: item.qtyOrdered,
          qtyIssued: item.qtyIssued, // Now validated to be equal to qtyOrdered
          unitPrice: 0, // Replace with actual price
          grossTotal: 0, // Replace with actual calculation
          discountP: 0,
          discount: 0,
          closingStock: item.stockQty - item.qtyIssued, // Update closing stock
          avgCost: 0, // Replace with actual cost
          srNo: item.serials.isNotEmpty ? item.serials.first.serialNo : null,
          soNumber: order.soNumber,
          cogsamt: 0,
          nonInventory: item.nonInventory,
          isFreeofCost: false,
          parentItem: null,
          qtyReserved: 0,
          poQty: 0,
          totReservedQty: 0,
          bSno: null,
          soQty: item.qtyOrdered,
          taxCode: null,
          taxPercentage: 0,
          binCode: null,
          commAmount: null,
          commission: null,
        );

        final detailQuery = '''
      INSERT INTO DnoteDetail (
        CmpyCode, DnNumber, LocCode, Sno, ItemCode, Barcode, Description, 
        Unit, QtyOrdered, QtyIssued, UnitPrice, GrossTotal, DiscountP, 
        Discount, ClosingStock, AvgCost, SrNo, SoNumber, cogsamt, 
        NonInventory, IsFreeofCost, ParentItem, QtyReserved, PoQty, 
        TotReservedQty, BSno, SoQty, TaxCode, TaxPercentage, BinCode, 
        CommAmount, Commission
      ) VALUES (
        '${detail.cmpyCode}', 
        '${detail.dnNumber}', 
        '${detail.locCode}', 
        ${detail.sno}, 
        '${detail.itemCode}', 
        ${detail.barcode != null ? "'${detail.barcode}'" : 'NULL'}, 
        '${detail.description}',
        '${detail.unit}', 
        ${detail.qtyOrdered}, 
        ${detail.qtyIssued}, 
        ${detail.unitPrice}, 
        ${detail.grossTotal}, 
        ${detail.discountP},
        ${detail.discount}, 
        ${detail.closingStock}, 
        ${detail.avgCost}, 
        ${detail.srNo != null ? "'${detail.srNo}'" : 'NULL'}, 
        '${detail.soNumber}', 
        ${detail.cogsamt},
        ${detail.nonInventory ? 1 : 0}, 
        ${detail.isFreeofCost ? 1 : 0}, 
        ${detail.parentItem != null ? "'${detail.parentItem}'" : 'NULL'}, 
        ${detail.qtyReserved}, 
        ${detail.poQty},
        ${detail.totReservedQty}, 
        ${detail.bSno != null ? "'${detail.bSno}'" : 'NULL'}, 
        ${detail.soQty}, 
        ${detail.taxCode != null ? "'${detail.taxCode}'" : 'NULL'}, 
        ${detail.taxPercentage},
        ${detail.binCode != null ? "'${detail.binCode}'" : 'NULL'}, 
        ${detail.commAmount ?? 'NULL'}, 
        ${detail.commission ?? 'NULL'}
      )
      ''';

        print('Posting detail for item ${item.itemCode}...');
        await _sqlConnection.writeData(detailQuery);
        print('Detail posted for item ${item.itemCode}');

        // 3. Post serial numbers if item is serialized
        if (item.serialYN && item.serials.isNotEmpty) {
          for (var serial in item.serials) {
            final serialDetail = InventoryDetailSerialNo(
              cmpyCode: order.companyCode,
              invNumber: '', // Will be invoice number if available
              sno: serial.sNo.toString(),
              itemCode: item.itemCode,
              serialNo: serial.serialNo,
              srNo: "1",
              dnNumber: deliveryNoteHeader.dnNumber,
              returnYN: false,
            );

            final serialQuery = '''
          INSERT INTO InvDetailSerials_DN (
            CmpyCode, InvNumber, Sno, ItemCode, SerialNo, SrNo, DnNumber, ReturnYN
          ) VALUES (
            '${serialDetail.cmpyCode}', 
            '${serialDetail.invNumber}', 
            '${serialDetail.sno}', 
            '${serialDetail.itemCode}', 
            '${serialDetail.serialNo}', 
            '${serialDetail.srNo}', 
            '${serialDetail.dnNumber}', 
            ${serialDetail.returnYN ? 1 : 0}
          )
          ''';

            print('Posting serial ${serial.serialNo}...');
            await _sqlConnection.writeData(serialQuery);
            print('Serial ${serial.serialNo} posted');
          }
        }
      }
      AppAlerts.appToast(message: "Delivery note posted successfully");
    } catch (e, stackTrace) {
      print('ERROR in postDeliveryNote:');
      print('Message: $e');
      print('Stack trace: $stackTrace');
      AppAlerts.appToast(
          message: "Failed to post delivery note: ${e.toString()}");
    }
  }

  // Scanner instance
  FlutterDataWedge? dataWedge;
  StreamSubscription? _scanSubscription;
  String _errorMessage = '';
  bool _isScannerActive = false;
  bool _scanCooldown = false;
  int _scanCount = 0;
  // Getters
  bool get isScannerActive => _isScannerActive;
  int get scanCount => _scanCount;

  void setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  Future<void> initializeScanner() async {
    try {
      setLoading(true);

      if (dataWedge == null) {
        dataWedge = FlutterDataWedge();
        await dataWedge!.initialize();
        await dataWedge!.createDefaultProfile(profileName: "DefaultProfile");
        debugPrint("Scanner initialized");
      }

      setLoading(false);
    } catch (e) {
      setLoading(false);
      debugPrint("Failed to initialize scanner: $e");
      // setErrorMessage("Scanner initialization failed. Please try again.");
      rethrow;
    }
  }

  // Add these to your OrderProvider
  String? _scannedBarcode;
  String? get scannedBarcode => _scannedBarcode;

  void clearScannedBarcode() {
    _scannedBarcode = null;
    notifyListeners();
  }


  Future<void> startScanning() async {
    try {
      notifyListeners();

      if (dataWedge == null) {
        await initializeScanner();
      }

      await dataWedge?.activateScanner(true);
      _scanSubscription?.cancel();

      _scanSubscription = dataWedge!.onScanResult.listen((result) async {
        if (_scanCooldown) return;

        final barcode = result.data.trim();
        if (barcode.isEmpty) return;

        _scanCount++;
        _scannedBarcode = barcode; // Store the scanned barcode
        notifyListeners();
        debugPrint('Scanned barcode: $barcode');

        // Add cooldown to prevent multiple scans
        _scanCooldown = true;
        Future.delayed(const Duration(milliseconds: 500), () {
          _scanCooldown = false;
        });
      });

      notifyListeners();
      debugPrint('Scanner started');
    } catch (e) {
      debugPrint('Error starting scanner: $e');
      await stopScanner();
      rethrow;
    }
  }




  Future<void> stopScanner() async {
    try {
      await dataWedge?.activateScanner(false);
      _scanSubscription?.cancel();
      _isScannerActive = false;
      debugPrint('Scanner stopped');
    } catch (e) {
      debugPrint("Failed to stop scanner: $e");
      rethrow;
    } finally {
      notifyListeners();
    }
  }


  SalesOrder? getSalesOrderById(String soNumber) {
    try {
      return _salesOrders.firstWhere((order) => order.soNumber == soNumber);
    } catch (e) {
      return null;
    }
  }

  Future<bool> isSerialUnique({
    required String serialNo,
    required String itemCode,
  }) async {
    try {
      // 1. Check current orders (only for matching itemCode)
      for (var order in salesOrders) {
        for (var item in order.items) {
          if (item.itemCode == itemCode && item.hasSerial(serialNo)) {
            return false;
          }
        }
      }

      // 2. SAFE DATABASE CHECK - Using proper parameterization
      final escapedSerial = serialNo.replaceAll("'", "''");
      final escapedItemCode = itemCode.replaceAll("'", "''");

      final result = await _sqlConnection.getData(
          "SELECT TOP 1 1 FROM InvDetailSerials "
          "WHERE SerialNo = '$escapedSerial' AND ItemCode = '$escapedItemCode'");

      return result.isEmpty ||
          result == "[]"; // Adapt based on your actual response format
    } catch (e) {
      print('Error checking serial uniqueness: $e');
      return false; // Fail-safe
    }
  }

  Future<void> addSerialToItem({
    required String soNumber,
    required String itemCode,
    required String serialNo,
  }) async {
    try {
      final order = getSalesOrderById(soNumber);
      if (order == null) throw Exception('Order not found');

      final item = order.items.firstWhere(
        (i) => i.itemCode == itemCode,
        orElse: () => throw Exception('Item not found'),
      );


      // Check if serial exists in other items or database
      final isUnique =
          await isSerialUnique(itemCode: itemCode, serialNo: serialNo);
      if (!isUnique) {
       return AppAlerts.appToast(message: 'Serial number $serialNo already exists in another item');
      }

      // if (item.hasSerial(serialNo)) {
      //   throw Exception('Serial number already exists for this item');
      // }

      // Stock validation for non-inventory items
      if (!item.nonInventory) {
        if (item.stockQty <= 0) {

          return AppAlerts.appToast(message: 'Insufficient stock for item ${item.itemCode}');
        }

        // Check if adding this serial would exceed available stock
        if (item.serials.length >= item.stockQty) {
          return AppAlerts.appToast(message:
              'Cannot add serial - would exceed available stock (${item.stockQty})');
        }
      }
      item.qtyIssued++;
      item.addSerial(serialNo);
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  void removeSerialFromItem({
    required String soNumber,
    required String itemCode,
    required String serialNo,
  }) {
    try {
      final order = getSalesOrderById(soNumber);
      if (order == null) throw Exception('Order not found');

      final item = order.items.firstWhere(
            (i) => i.itemCode == itemCode,
        orElse: () => throw Exception('Item not found'),
      );

      final initialLength = item.serials.length;
      item.serials.removeWhere((s) => s.serialNo == serialNo);

      // Only decrement if a serial was actually removed
      if (item.serials.length < initialLength) {
        item.qtyIssued -= 1;
      }

      // Recalculate positions
      for (int i = 0; i < item.serials.length; i++) {
        item.serials[i] = ItemSerial(
          serialNo: item.serials[i].serialNo,
          sNo: i + 1,
        );
      }
      notifyListeners();
    } catch (e) {
      throw Exception('Failed to remove serial: ${e.toString()}');
    }
  }


  void resetValidation() {
    isValidForPosting = true;
    validationMessage = '';
    notifyListeners();
  }
}
