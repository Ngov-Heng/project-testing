// Email and phone: normalise first, then validate.

String normalizeEmail(String email) => email.trim().toLowerCase();

String normalizePhone(String phone) =>
    phone.replaceAll(RegExp(r'[\s\-().]'), '');

bool isValidEmail(String email) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
bool isValidPhone(String phone) => RegExp(r'^\+?[0-9]{8,15}$').hasMatch(phone);
