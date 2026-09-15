import {
  computeBoundedMaxEndFromRowsAndChanges,
  computeParentEndFromRowsAndChanges,
  hasExtensionBeyondContractEnd,
  hasExtensionBeyondOrderEnd,
  findRemovedParentRowForReplacementChild,
  isReplacedParentVisibleInGrid,
  resolveReplacementRowStatus,
  shouldShowStatusNewProductPlusIcon,
  findActiveOrderLineForDraftRow,
  activeOrderLineEndDateYmd,
  replaceModalPeriodEndFloorYmd,
  endDateYmdToRestoreAfterClearedTermination,
  draftRowForClearedTerminationRestore,
  orderItemTerminationReasonPresent,
  monthlyAccessTypeFromRow,
  isReplacedMovingOutLineId,
  maxSelectedProductEndDateYmd,
  isExitDateAfterProductMax,
  shouldApplyTerminateToProduct,
  isCatalogLineActive,
  clearOrphanReplacedOrderProductId,
  pastStartSignedBlockMessage,
  SIGNED_PAST_START_ADMIN_MESSAGE
} from "../packageBuilderTableUtils";

const normId = (value) => {
  const s = String(value || "").trim();
  return s ? s.substring(0, 15).toLowerCase() : "";
};

describe("findRemovedParentRowForReplacementChild", () => {
  const parent = {
    LineItemId: "001RemovedParent1",
    ChangeType: "Removed",
    EndDate: "2026-11-13"
  };
  const child = {
    LineItemId: "001ReplacementCh1",
    ChangeType: "New",
    ReplacedOrderProductId: "001RemovedParent1",
    ServiceDate: "2026-11-14"
  };

  it("finds parent via explicit ReplacedOrderProductId", () => {
    const found = findRemovedParentRowForReplacementChild(
      child,
      [parent, child],
      normId
    );
    expect(found).toBe(parent);
  });

  it("finds parent via date adjacency when lookup was cleared", () => {
    const childNoLink = {
      LineItemId: "001ReplacementCh2",
      ChangeType: "New",
      ServiceDate: "2026-11-14"
    };
    const found = findRemovedParentRowForReplacementChild(
      childNoLink,
      [parent, childNoLink],
      normId
    );
    expect(found).toBe(parent);
  });

  it("returns null when no Removed parent matches", () => {
    const orphan = {
      LineItemId: "001Orphan00001",
      ChangeType: "New",
      ServiceDate: "2026-12-01"
    };
    expect(
      findRemovedParentRowForReplacementChild(orphan, [parent], normId)
    ).toBeNull();
  });
});

describe("isReplacedParentVisibleInGrid", () => {
  it("returns true when parent row is in allRows", () => {
    const parent = { LineItemId: "001RemovedParent1" };
    expect(
      isReplacedParentVisibleInGrid("001RemovedParent1", [parent], normId)
    ).toBe(true);
  });

  it("returns false when parent id is absent from allRows (soft-deleted / hidden)", () => {
    expect(isReplacedParentVisibleInGrid("001RemovedParent1", [], normId)).toBe(
      false
    );
  });
});

describe("resolveReplacementRowStatus", () => {
  const parent = {
    LineItemId: "001RemovedParent1",
    ChangeType: "Removed",
    EndDate: "2026-06-04"
  };
  const child = {
    LineItemId: "001ReplacementCh1",
    ChangeType: "No Change",
    ReplacedOrderProductId: "001RemovedParent1",
    ServiceDate: "2026-06-05"
  };
  const replacedById = new Set(["001RemovedParent1"]);
  const replacementChildIds = new Set();

  it("shows moving-in when parent is visible in grid", () => {
    const status = resolveReplacementRowStatus({
      row: child,
      allRows: [parent, child],
      replacedById,
      replacementChildIds,
      normalizeRowIdFn: normId,
      changeType: "No Change"
    });
    expect(status.hasReplacementLink).toBe(true);
    expect(status.isMovingInRow).toBe(true);
    expect(status.showMovingInIcon).toBe(true);
    expect(status.blocksReplace).toBe(true);
    expect(status.isMovingOutRow).toBe(false);
  });

  it("suppresses moving-in when parent is not in grid (orphan replacement)", () => {
    const status = resolveReplacementRowStatus({
      row: child,
      allRows: [child],
      replacedById,
      replacementChildIds,
      normalizeRowIdFn: normId,
      changeType: "No Change"
    });
    expect(status.hasReplacementLink).toBe(true);
    expect(status.isMovingInRow).toBe(true);
    expect(status.showMovingInIcon).toBe(false);
    expect(status.blocksReplace).toBe(false);
  });

  it("classifies Removed parent as moving-out", () => {
    const status = resolveReplacementRowStatus({
      row: parent,
      allRows: [parent, child],
      replacedById,
      replacementChildIds,
      normalizeRowIdFn: normId,
      changeType: "Removed"
    });
    expect(status.isMovingOutRow).toBe(true);
    expect(status.showMovingInIcon).toBe(false);
  });
});

describe("findActiveOrderLineForDraftRow", () => {
  const activeLine = {
    LineItemId: "001ActiveLine0001",
    EndDate: "2027-06-30",
    Original_End_Date__c: "2028-12-31"
  };

  it("finds active line by Original_Order_Product__c (15-char ids)", () => {
    const draftRow = {
      LineItemId: "001DraftLine00001",
      Original_Order_Product__c: "001ActiveLine0001"
    };
    const found = findActiveOrderLineForDraftRow(
      draftRow,
      [activeLine],
      normId
    );
    expect(found).toBe(activeLine);
  });

  it("finds active line by matching draft id before Original_Order_Product__c is set", () => {
    const draftRow = { LineItemId: "001ActiveLine0001" };
    const found = findActiveOrderLineForDraftRow(
      draftRow,
      [activeLine],
      normId
    );
    expect(found).toBe(activeLine);
  });

  it("returns null when no active match", () => {
    expect(
      findActiveOrderLineForDraftRow(
        {
          LineItemId: "001Unknown00001",
          Original_Order_Product__c: "001Missing00001"
        },
        [activeLine],
        normId
      )
    ).toBeNull();
  });
});

describe("activeOrderLineEndDateYmd", () => {
  it("prefers live EndDate over Original_End_Date__c", () => {
    expect(
      activeOrderLineEndDateYmd({
        EndDate: "2026-11-18",
        Original_End_Date__c: "2028-06-01"
      })
    ).toBe("2026-11-18");
  });

  it("falls back to Original_End_Date__c when live EndDate is unset", () => {
    expect(
      activeOrderLineEndDateYmd({
        Original_End_Date__c: "2028-06-01"
      })
    ).toBe("2028-06-01");
  });

  it("falls back to EndDate when original end is unset", () => {
    expect(activeOrderLineEndDateYmd({ EndDate: "2027-03-15" })).toBe(
      "2027-03-15"
    );
  });
});

describe("replaceModalPeriodEndFloorYmd", () => {
  it("uses draft end when terminated draft is shortened below active", () => {
    expect(
      replaceModalPeriodEndFloorYmd({
        isTerminatedDraftRow: true,
        draftEndYmd: "2026-07-14",
        activeEndYmd: "2026-12-31"
      })
    ).toBe("2026-07-14");
  });

  it("keeps active end when not terminated", () => {
    expect(
      replaceModalPeriodEndFloorYmd({
        isTerminatedDraftRow: false,
        draftEndYmd: "2026-07-14",
        activeEndYmd: "2026-12-31"
      })
    ).toBe("2026-12-31");
  });

  it("keeps active end when terminated draft end is not before active", () => {
    expect(
      replaceModalPeriodEndFloorYmd({
        isTerminatedDraftRow: true,
        draftEndYmd: "2026-12-31",
        activeEndYmd: "2026-12-31"
      })
    ).toBe("2026-12-31");
  });

  it("returns null when active end is missing and exception does not apply", () => {
    expect(
      replaceModalPeriodEndFloorYmd({
        isTerminatedDraftRow: false,
        draftEndYmd: "2026-07-14",
        activeEndYmd: null
      })
    ).toBeNull();
  });
});

describe("draftRowForClearedTerminationRestore", () => {
  it("does not restore when wire row never had a termination reason", () => {
    const sourceRow = {
      LineItemId: "001DraftLine00001",
      EndDate: "2026-06-14",
      Termination_Reason__c: null
    };
    const lookupRow = draftRowForClearedTerminationRestore(sourceRow, {
      TerminationReason: ""
    });
    const activeLine = {
      LineItemId: "001ActiveLine0001",
      EndDate: "2026-06-30"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(lookupRow, activeLine)
    ).toBe("2026-06-30");
    // Caller must gate on hadTermination; helper alone only checks cleared fields + date math.
    expect(orderItemTerminationReasonPresent(sourceRow)).toBe(false);
  });

  it("strips wire termination fields so restore runs after inline clear", () => {
    const sourceRow = {
      LineItemId: "001DraftLine00001",
      EndDate: "2026-06-14",
      Termination_Reason__c: "Dissatisfaction",
      TerminationReasonLabel: "Dissatisfaction"
    };
    const lookupRow = draftRowForClearedTerminationRestore(sourceRow, {
      TerminationReason: ""
    });
    const activeLine = {
      LineItemId: "001ActiveLine0001",
      EndDate: "2026-06-30"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(lookupRow, activeLine)
    ).toBe("2026-06-30");
  });
});

describe("endDateYmdToRestoreAfterClearedTermination", () => {
  const activeLine = { LineItemId: "001ActiveLine0001", EndDate: "2026-06-30" };

  it("restores curtailed Periodic draft end from active line (product 317 pattern)", () => {
    const draftRow = {
      LineItemId: "001DraftLine00001",
      Access_Type__c: "Periodic",
      EndDate: "2026-06-22",
      Original_End_Date__c: "2026-06-30",
      Original_Order_Product__c: "001ActiveLine0001",
      Termination_Reason__c: null
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(draftRow, activeLine)
    ).toBe("2026-06-30");
  });

  it("returns null when termination reason is still set", () => {
    expect(
      endDateYmdToRestoreAfterClearedTermination(
        { EndDate: "2026-06-22", Termination_Reason__c: "Other" },
        activeLine
      )
    ).toBeNull();
  });

  it("does not restore replacement-parent curtailed end from active line", () => {
    const draftRow = {
      LineItemId: "001SuiteB",
      EndDate: "2026-07-08",
      Original_End_Date__c: "2027-05-31",
      Original_Order_Product__c: "001ActiveSuiteB",
      Termination_Reason__c: null
    };
    const activeSuiteB = {
      LineItemId: "001ActiveSuiteB",
      EndDate: "2027-05-31",
      Original_End_Date__c: "2027-05-31"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(draftRow, activeSuiteB, {
        keepCurtailedEndForReplacement: true
      })
    ).toBeNull();
  });

  it("does not restore Monthly draft end from still-terminated active line", () => {
    const draftRow = {
      Access_Type__c: "Monthly",
      EndDate: null,
      Original_Order_Product__c: "001ActiveLine0001",
      Termination_Reason__c: null
    };
    const activeLineTerminated = {
      LineItemId: "001ActiveLine0001",
      Access_Type__c: "Monthly",
      EndDate: "2026-06-22",
      Termination_Reason__c: "Other"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(draftRow, activeLineTerminated)
    ).toBeNull();
  });

  it("does not pull Periodic end from still-terminated active line when draft was extended", () => {
    const draftRow = {
      Access_Type__c: "Periodic",
      EndDate: "2027-12-31",
      Original_End_Date__c: "2026-06-22",
      Original_Order_Product__c: "001ActiveLine0001",
      Termination_Reason__c: null
    };
    const activeLineTerminated = {
      LineItemId: "001ActiveLine0001",
      EndDate: "2026-06-22",
      Original_End_Date__c: "2026-06-30",
      Termination_Reason__c: "Dissatisfaction"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(draftRow, activeLineTerminated)
    ).toBeNull();
  });

  it("restores Periodic draft from archived original when active line is still terminated", () => {
    const draftRow = {
      Access_Type__c: "Periodic",
      EndDate: null,
      Original_End_Date__c: "2026-06-30",
      Original_Order_Product__c: "001ActiveLine0001",
      Termination_Reason__c: null
    };
    const activeLineTerminated = {
      LineItemId: "001ActiveLine0001",
      EndDate: "2026-06-22",
      Termination_Reason__c: "Other"
    };
    expect(
      endDateYmdToRestoreAfterClearedTermination(draftRow, activeLineTerminated)
    ).toBe("2026-06-30");
  });
});

describe("monthlyAccessTypeFromRow", () => {
  it("detects Monthly access type", () => {
    expect(monthlyAccessTypeFromRow({ Access_Type__c: "Monthly" })).toBe(true);
    expect(monthlyAccessTypeFromRow({ AccessType: "monthly" })).toBe(true);
    expect(monthlyAccessTypeFromRow({ Access_Type__c: "Periodic" })).toBe(
      false
    );
  });
});

describe("isReplacedMovingOutLineId", () => {
  it("returns true when id is in replacedById set", () => {
    const replacedById = new Set(["001Parent"]);
    expect(isReplacedMovingOutLineId("001Parent", replacedById)).toBe(true);
    expect(isReplacedMovingOutLineId("001Child", replacedById)).toBe(false);
  });
});

describe("shouldShowStatusNewProductPlusIcon", () => {
  it("shows green plus only for effective new lines without a replacement link", () => {
    expect(
      shouldShowStatusNewProductPlusIcon({
        isContractActiveContext: false,
        isEffectiveNew: true,
        replacementIcon: "",
        replacedOrderProductId: null
      })
    ).toBe(true);
  });

  it("hides green plus for moving-in replacement", () => {
    expect(
      shouldShowStatusNewProductPlusIcon({
        isContractActiveContext: false,
        isEffectiveNew: true,
        replacementIcon: "moving-in",
        replacedOrderProductId: "001Parent"
      })
    ).toBe(false);
  });

  it("shows green plus for effective new line with orphan lookup when replacement icon is suppressed", () => {
    expect(
      shouldShowStatusNewProductPlusIcon({
        isContractActiveContext: false,
        isEffectiveNew: true,
        replacementIcon: "",
        replacedOrderProductId: "001RemovedParent1"
      })
    ).toBe(true);
  });
});

describe("maxSelectedProductEndDateYmd", () => {
  it("returns max of normalized end dates", () => {
    expect(
      maxSelectedProductEndDateYmd(["2026-09-15", "2027-06-03", "2026-06-02"])
    ).toBe("2027-06-03");
  });

  it("returns null when any end date is blank", () => {
    expect(maxSelectedProductEndDateYmd(["2027-06-03", null])).toBe(null);
    expect(maxSelectedProductEndDateYmd(["2027-06-03", ""])).toBe(null);
  });

  it("returns null for empty array", () => {
    expect(maxSelectedProductEndDateYmd([])).toBe(null);
  });
});

describe("isExitDateAfterProductMax", () => {
  it("is true when exit exceeds latest product end", () => {
    expect(
      isExitDateAfterProductMax("2028-10-18", ["2027-06-03", "2026-09-15"])
    ).toBe(true);
  });

  it("is false when exit equals max product end", () => {
    expect(isExitDateAfterProductMax("2027-06-03", ["2027-06-03"])).toBe(false);
  });

  it("is false when selection has blank end (no bounded max)", () => {
    expect(isExitDateAfterProductMax("2028-10-18", [null])).toBe(false);
  });
});

describe("shouldApplyTerminateToProduct", () => {
  it("applies when product end is on or after exit date", () => {
    expect(shouldApplyTerminateToProduct("2028-03-13", "2028-03-13")).toBe(
      true
    );
    expect(shouldApplyTerminateToProduct("2028-06-01", "2028-03-13")).toBe(
      true
    );
  });

  it("skips when product end is before exit date", () => {
    expect(shouldApplyTerminateToProduct("2026-07-01", "2028-03-13")).toBe(
      false
    );
  });

  it("applies when product end is blank (open-ended)", () => {
    expect(shouldApplyTerminateToProduct(null, "2028-03-13")).toBe(true);
    expect(shouldApplyTerminateToProduct("", "2028-03-13")).toBe(true);
  });

  it("returns false when exit date is missing", () => {
    expect(shouldApplyTerminateToProduct("2028-03-13", null)).toBe(false);
  });
});

describe("isCatalogLineActive", () => {
  it("is true when both Product2 and PricebookEntry are active", () => {
    expect(
      isCatalogLineActive({
        ProductIsActive: true,
        PricebookEntryIsActive: true
      })
    ).toBe(true);
  });

  it("is false when Product2 is inactive", () => {
    expect(
      isCatalogLineActive({
        ProductIsActive: false,
        PricebookEntryIsActive: true
      })
    ).toBe(false);
  });

  it("is false when PricebookEntry is inactive", () => {
    expect(
      isCatalogLineActive({
        ProductIsActive: true,
        PricebookEntryIsActive: false
      })
    ).toBe(false);
  });

  it("defaults to true when active flags are missing (legacy rows)", () => {
    expect(isCatalogLineActive({ LineItemId: "001abc" })).toBe(true);
  });
});

describe("clearOrphanReplacedOrderProductId", () => {
  it("clears replacement link when parent was not kept in draft", () => {
    const child = {
      LineItemId: "001Child0000001",
      ReplacedOrderProductId: "001Parent000001"
    };
    const kept = new Set(["001child0000001"]);
    const cleared = clearOrphanReplacedOrderProductId(child, kept, normId);
    expect(cleared.ReplacedOrderProductId).toBeUndefined();
  });

  it("keeps replacement link when parent is in kept set", () => {
    const child = {
      LineItemId: "001Child0000001",
      ReplacedOrderProductId: "001Parent000001"
    };
    const kept = new Set(["001parent000001"]);
    const keptChild = clearOrphanReplacedOrderProductId(child, kept, normId);
    expect(keptChild.ReplacedOrderProductId).toBe("001Parent000001");
  });
});

describe("computeBoundedMaxEndFromRowsAndChanges", () => {
  const rows = [
    { LineItemId: "001Monthly", EndDate: null },
    { LineItemId: "001Periodic", EndDate: "2026-06-05" }
  ];

  it("returns max bounded end when open-ended lines exist (Monthly does not block extension)", () => {
    const updates = [{ Id: "001Periodic", EndDate: "2027-12-31" }];
    expect(
      computeBoundedMaxEndFromRowsAndChanges(rows, updates, false).targetEndYmd
    ).toBe("2027-12-31");
  });

  it("open-ended-wins rollup returns null for the same data", () => {
    const updates = [{ Id: "001Periodic", EndDate: "2027-12-31" }];
    expect(
      computeParentEndFromRowsAndChanges(rows, updates, false).targetEndYmd
    ).toBe(null);
  });
});

describe("hasExtensionBeyondContractEnd / hasExtensionBeyondOrderEnd", () => {
  it("detects extension beyond contract end in save payload", () => {
    expect(
      hasExtensionBeyondContractEnd(
        [{ Id: "001", EndDate: "2027-06-01" }],
        "2026-06-05",
        false
      )
    ).toBe(true);
  });

  it("detects extension beyond order end when contract end is blank", () => {
    expect(
      hasExtensionBeyondOrderEnd(
        [{ Id: "001", EndDate: "2027-06-01" }],
        "2026-06-05",
        false
      )
    ).toBe(true);
  });
});

describe("pastStartSignedBlockMessage", () => {
  const today = "2026-07-21";

  it("blocks non-admin when order start is before today", () => {
    expect(pastStartSignedBlockMessage("2026-07-20", today, false)).toBe(
      SIGNED_PAST_START_ADMIN_MESSAGE
    );
  });

  it("allows admin override when order start is before today", () => {
    expect(pastStartSignedBlockMessage("2026-07-20", today, true)).toBe(null);
  });

  it("allows when order start is today", () => {
    expect(pastStartSignedBlockMessage(today, today, false)).toBe(null);
  });

  it("allows when order start is in the future", () => {
    expect(pastStartSignedBlockMessage("2026-07-22", today, false)).toBe(null);
  });

  it("does not restrict when order start is blank", () => {
    expect(pastStartSignedBlockMessage(null, today, false)).toBe(null);
    expect(pastStartSignedBlockMessage("", today, false)).toBe(null);
    expect(pastStartSignedBlockMessage(undefined, today, false)).toBe(null);
  });

  it("does not restrict when today is blank", () => {
    expect(pastStartSignedBlockMessage("2026-07-20", null, false)).toBe(null);
  });

  it("normalizes Date inputs to calendar day", () => {
    expect(
      pastStartSignedBlockMessage(new Date(2026, 6, 20), "2026-07-21", false)
    ).toBe(SIGNED_PAST_START_ADMIN_MESSAGE);
  });

  it("treats ISO datetime prefix as date-only", () => {
    expect(
      pastStartSignedBlockMessage("2026-07-20T15:00:00.000Z", today, false)
    ).toBe(SIGNED_PAST_START_ADMIN_MESSAGE);
  });

  it("allows far-future starts", () => {
    expect(pastStartSignedBlockMessage("2099-01-01", today, false)).toBe(null);
  });

  it("blocks far-past starts", () => {
    expect(pastStartSignedBlockMessage("2000-01-01", today, false)).toBe(
      SIGNED_PAST_START_ADMIN_MESSAGE
    );
  });

  it("does not restrict invalid date strings", () => {
    expect(pastStartSignedBlockMessage("not-a-date", today, false)).toBe(null);
  });

  it("override wins even when today is also blank", () => {
    expect(pastStartSignedBlockMessage("2026-07-20", null, true)).toBe(null);
  });

  it("does not treat EffectiveDate-like values specially (caller must pass Order_Start_Date only)", () => {
    // If a caller mistakenly passed a past EffectiveDate while Order_Start_Date__c is null,
    // the helper would block — wiring must use orderStartDateOnly, not effectiveDate fallback.
    expect(pastStartSignedBlockMessage("2020-01-01", today, false)).toBe(
      SIGNED_PAST_START_ADMIN_MESSAGE
    );
  });
});
