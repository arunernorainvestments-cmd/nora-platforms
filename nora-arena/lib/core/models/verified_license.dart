// Shape returned by the N.O.R.A. licensing API (lkn-verify).
// List mode (?licensee_nora_id=) returns a JSON array of these.

class VerifiedLicense {
  final String licenseId;
  final String licenseStatus; // active | expired | revoked | not_found
  final String? licensorNoraId;
  final bool useCategoryPermitted;
  final String? effectiveDate;
  final String? expirationDate;

  // Present only in single-license mode (signed). Used at battle-start re-verify.
  final String? recordHash;
  final String? signature;

  const VerifiedLicense({
    required this.licenseId,
    required this.licenseStatus,
    required this.licensorNoraId,
    required this.useCategoryPermitted,
    this.effectiveDate,
    this.expirationDate,
    this.recordHash,
    this.signature,
  });

  bool get isActive => licenseStatus == 'active';
  bool get isPlayable => isActive && useCategoryPermitted;

  factory VerifiedLicense.fromJson(Map<String, dynamic> json) {
    final licensor = json['licensor'];
    return VerifiedLicense(
      licenseId: json['license_id'] as String,
      licenseStatus: json['license_status'] as String? ?? 'not_found',
      licensorNoraId:
          licensor is Map ? licensor['nora_id'] as String? : null,
      useCategoryPermitted: json['use_category_permitted'] == true,
      effectiveDate: json['effective_date'] as String?,
      expirationDate: json['expiration_date'] as String?,
      recordHash: json['record_hash'] as String?,
      signature: json['signature'] as String?,
    );
  }
}
