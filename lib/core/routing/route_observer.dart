import "package:flutter/material.dart";

/// 全域共用的 [RouteObserver]，掛在 `MaterialApp.navigatorObservers` 上。
///
/// 用途：頁面用 [RouteAware] 訂閱「自己再次成為 top route」事件（didPopNext），
/// 觸發例如「教學版本被重設後、回到首頁立刻重新顯示教學」這類需求。
final RouteObserver<ModalRoute<void>> appRouteObserver =
		RouteObserver<ModalRoute<void>>();
