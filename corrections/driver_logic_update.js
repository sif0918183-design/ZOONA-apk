/**
 * هذا الكود يجب دمجه في تطبيق السائق PWA (zoona-driver)
 * لضمان التنسيق مع تطبيق Flutter WebView
 */

// 1. عند نجاح عملية تسجيل الدخول
async function onDriverLoginSuccess(driverData) {
    // تخزين المعرف في localStorage ليتمكن تطبيق Flutter من التقاطه
    localStorage.setItem('driver_id', driverData.id);
    localStorage.setItem('tarhal_driver_id', driverData.id); // للاحتياط

    console.log("🎯 Driver ID stored in localStorage for Flutter sync");

    // إذا كان التطبيق يعمل في المتصفح العادي (وليس WebView)
    if (window.OneSignal) {
        await OneSignal.setExternalUserId(driverData.id);
    }
}

// 2. دالة استقبال طلبات الرحلة (يستدعيها تطبيق Flutter)
window.handleRideRequest = function(data) {
    console.log("📥 New ride request received via Flutter:", data);

    // تحديث الواجهة أو فتح مودال الرحلة
    if (typeof showRideRequestModal === 'function') {
        showRideRequestModal(data);
    } else {
        // إذا لم تكن الدالة موجودة، يمكن الانتقال لصفحة قبول الرحلة
        const url = `accept-ride.html?rideId=${data.rideId}&requestId=${data.requestId}`;
        window.location.href = url;
    }
};

// 3. دالة إظهار التنبيهات (يستدعيها تطبيق Flutter)
window.showNotification = function(message, type) {
    console.log(`🔔 Notification from Flutter: [${type}] ${message}`);
    // استخدم نظام التنبيهات الخاص بك (مثلاً Toastify أو SweetAlert)
    alert(message);
};
