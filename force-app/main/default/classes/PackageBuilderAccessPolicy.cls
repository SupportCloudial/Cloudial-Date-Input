public with sharing class PackageBuilderAccessPolicy {
    public static final String ENTRY_DATE_ADMIN_OVERRIDE_PERMISSION = 'PackageBuilder_EntryDate_AdminOverride';
    public static final String TERMINATED_END_DATE_ADMIN_OVERRIDE_PERMISSION =
        'PackageBuilder_TerminatedEndDate_AdminOverride';

    @TestVisible
    private static Boolean testEntryDateAdminOverride;

    @TestVisible
    private static Boolean testTerminatedEndDateAdminOverride;

    public static Boolean hasEntryDateAdminOverride() {
        if (testEntryDateAdminOverride != null) {
            return testEntryDateAdminOverride;
        }
        return FeatureManagement.checkPermission(ENTRY_DATE_ADMIN_OVERRIDE_PERMISSION);
    }

    public static Boolean hasTerminatedEndDateAdminOverride() {
        if (testTerminatedEndDateAdminOverride != null) {
            return testTerminatedEndDateAdminOverride;
        }
        return FeatureManagement.checkPermission(TERMINATED_END_DATE_ADMIN_OVERRIDE_PERMISSION);
    }

    public static Boolean canEditEntryDate(Date entryDate) {
        return hasEntryDateAdminOverride() || (entryDate != null && entryDate >= Date.today());
    }

    /** Terminated draft lines: extend inline; shorten only with admin override or via Terminate Products. */
    public static Boolean canShortenTerminatedEndDate(Date currentEnd, Date newEnd) {
        if (newEnd == null || currentEnd == null) {
            return true;
        }
        if (hasTerminatedEndDateAdminOverride()) {
            return true;
        }
        return newEnd >= currentEnd;
    }
}