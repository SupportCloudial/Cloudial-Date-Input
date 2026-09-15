import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import packageBuilderConfirmModal from "c/packageBuilderConfirmModal";
import loadIterations from "@salesforce/apex/IterationController.loadIterations";
import saveIterations from "@salesforce/apex/IterationController.saveIterations";
import bulkApply from "@salesforce/apex/IterationController.bulkApply";
import approveIteration from "@salesforce/apex/IterationController.approveIteration";
import rejectProposed from "@salesforce/apex/IterationController.rejectProposed";
import saveProposed from "@salesforce/apex/IterationController.saveProposed";
import revertWorkingToOriginal from "@salesforce/apex/IterationController.revertWorkingToOriginal";
import getHistoryEventsForIterations from "@salesforce/apex/IterationController.getHistoryEventsForIterations";
import {
  INCREASE_TYPE_OPTIONS,
  applyAllPendingDrafts,
  buildCopyFromConfirmMessage,
  buildCopyFromResultMessage,
  copyFromBlockedReason,
  buildBulkApplyRequest,
  buildBulkTemplateFromForm,
  buildIterationColumns,
  buildProposedPayload,
  addIterationRowForTile,
  removeIterationRowsForTile,
  iterationsByKeys,
  chipActionUiState,
  groupScreenRowsIntoTiles,
  groupHistoryEventsByIteration,
  increaseValueForDisplay,
  iterationsForSave,
  mapLoadedIterationRows,
  mergeTileDraftValues,
  resolveProposeTargetIterations,
  resolveFanOutIterationIds,
  resolveHistoryIterationIds,
  setSelectedIterationKeys,
  hasPendingDatatableDrafts,
  summarizeCopyFromPlan,
  validateBulkCommercialForm,
  validateScreenRowsCommercial
} from "./iterationsUtils";

const EMPTY_ROW_KEYS = Object.freeze([]);

export default class PackageBuilderIterationsModal extends LightningElement {
  @api isArchived = false;

  _context = "Contract";
  @api
  get context() {
    return this._context;
  }
  set context(value) {
    this._context = value || "Contract";
    if (this._lineIds.length) {
      this._scheduleLoadRows();
    }
  }

  @track screenRows = [];
  @track excludedMessage = "";
  @track bulkFeedbackMessage = "";
  @track isLoading = false;
  @track isSaving = false;
  @track isApproving = false;
  @track isActionBusy = false;
  @track isDeleting = false;
  @track isBulkApplying = false;
  @track showBulkPanel = false;

  @track bulkDuration = null;
  @track bulkNotice = null;
  @track bulkIncreaseType = "";
  @track bulkIncreaseValue = null;
  @track bulkProposedType = "";
  @track bulkProposedValue = null;

  /** tileKey -> selected iteration row keys */
  @track tileSelectedRowKeys = {};
  /** tileKey -> propose panel open */
  @track tileProposeOpen = {};
  /** tileKey -> proposed type/value form */
  @track tileProposeType = {};
  @track tileProposeValue = {};
  /** tileKey -> source tileKey for Copy from... */
  @track tileCopySourceKeys = {};
  /** tileKey -> Copy from source picker visible */
  @track tileCopyFromOpen = {};

  /** @type {{ tileKey: string, lineId: string, iterationIds: string[], sections: Array, loading: boolean, error: string } | null} */
  @track historyPanel = null;
  /** @type {{ tileKey: string, action: 'history' | 'revert' } | null} */
  @track productPicker = null;

  increaseTypeOptions = INCREASE_TYPE_OPTIONS;

  _lineIds = [];
  _loadScheduled = false;
  _isDirty = false;
  _loadGeneration = 0;

  @api
  get lineIds() {
    return this._lineIds;
  }

  set lineIds(value) {
    this._lineIds = value || [];
    if (!this._lineIds.length) {
      this._resetModalState();
      return;
    }
    this._scheduleLoadRows();
  }

  _resetModalState() {
    this.screenRows = [];
    this.excludedMessage = "";
    this.bulkFeedbackMessage = "";
    this.historyPanel = null;
    this.productPicker = null;
    this._isDirty = false;
    this._resetTileState();
  }

  _resetTileState() {
    this.tileSelectedRowKeys = {};
    this.tileProposeOpen = {};
    this.tileProposeType = {};
    this.tileProposeValue = {};
    this.tileCopySourceKeys = {};
    this.tileCopyFromOpen = {};
    this.productPicker = null;
  }

  _scheduleLoadRows() {
    if (this._loadScheduled) {
      return;
    }
    this._loadScheduled = true;
    Promise.resolve().then(() => {
      this._loadScheduled = false;
      this._loadRows();
    });
  }

  get hasRows() {
    return !this.isLoading && this.screenRows.length > 0;
  }

  get iterationColumns() {
    return buildIterationColumns();
  }

  get displayTiles() {
    const busy =
      this.isApproving ||
      this.isActionBusy ||
      this.isDeleting ||
      this.isLoading ||
      this.isSaving;
    const hasUnsaved = this._isDirty;
    const history = this.historyPanel;
    const productPicker = this.productPicker;
    const tiles = groupScreenRowsIntoTiles(this.screenRows);

    return tiles.map((tile) => {
      const tileKey = tile.tileKey;
      const anchorRow = tile.anchorProduct;
      const selectedRowKeys = this._trackedSelectedRowKeys(tileKey, anchorRow);
      const lineIds = tile.products.map((p) => p.lineId);

      const chips = tile.products.map((p) => ({
        lineId: p.lineId,
        label: p.displayName
      }));

      const actionState = chipActionUiState(
        tile.productCount,
        null,
        anchorRow.iterations,
        selectedRowKeys,
        busy,
        tile.products[0]
      );
      const proposeTargets = resolveProposeTargetIterations(
        anchorRow.iterations,
        selectedRowKeys
      );
      const proposeOpen = this.tileProposeOpen[tileKey] === true;
      const proposeSubtitle =
        proposeOpen && proposeTargets.length
          ? proposeTargets.length === 1
            ? "Proposing for Iteration " +
              String(proposeTargets[0].Sequence__c ?? "")
            : "Proposing for " + String(proposeTargets.length) + " iterations"
          : "";

      const copySourceOptions = tiles
        .filter((t) => t.tileKey !== tileKey)
        .filter((t) => {
          const sourceAnchorRow = this.screenRows.find(
            (r) => r.lineId === t.anchorLineId
          );
          return !copyFromBlockedReason(sourceAnchorRow?.iterations || []);
        })
        .map((t, sourceIndex) => ({
          value: t.tileKey,
          label:
            t.productCount === 1
              ? t.products[0]?.displayName || "Plan " + String(sourceIndex + 1)
              : "Plan (" + String(t.productCount) + " products)"
        }));
      const copySourceKey =
        this.tileCopySourceKeys[tileKey] ||
        (copySourceOptions[0] ? copySourceOptions[0].value : "");

      const historyOpen = history && history.tileKey === tileKey;
      const productPickerOpen =
        productPicker && productPicker.tileKey === tileKey;
      const productPickerTitle =
        productPicker?.action === "revert"
          ? "Select a product to Restore original"
          : "Select a product for History";

      const selectedIterations = iterationsByKeys(
        anchorRow.iterations,
        selectedRowKeys
      );
      let deleteDisabled = true;
      let deleteTitle = "Select one or more iterations to delete.";
      if (selectedIterations.length > 0) {
        if (selectedIterations.some((it) => it.Status__c === "Completed")) {
          deleteTitle = "Completed iterations cannot be deleted.";
        } else if (selectedIterations.some((it) => it.Id) && hasUnsaved) {
          deleteTitle = "Save or discard changes before deleting an iteration.";
        } else if (busy) {
          deleteTitle = "Please wait…";
        } else {
          deleteDisabled = false;
          deleteTitle =
            selectedIterations.length === 1
              ? "Delete the selected iteration"
              : "Delete " +
                String(selectedIterations.length) +
                " selected iterations";
        }
      }

      return {
        tileKey,
        productCount: tile.productCount,
        tileTitle:
          tile.productCount === 1
            ? "Plan Iterations · " +
              (tile.products[0]?.displayName || "Product")
            : "Plan Iterations (" + String(tile.productCount) + " products)",
        showProductList: tile.productCount > 1,
        productPickerOpen,
        productPickerTitle,
        showCopyFrom: copySourceOptions.length > 0,
        showCopyFromPicker: !!this.tileCopyFromOpen[tileKey],
        copySourceOptions,
        copySourceKey,
        copyFromDisabled:
          busy ||
          this.isSaving ||
          (!!this.tileCopyFromOpen[tileKey] && !copySourceKey),
        chips,
        iterations: anchorRow.iterations,
        anchorLineId: anchorRow.lineId,
        lineIds,
        selectedRowKeys,
        draftValues: anchorRow.draftValues || [],
        proposeOpen,
        proposeType: this.tileProposeType[tileKey] || "",
        proposeValue: this.tileProposeValue[tileKey] ?? null,
        proposeSubtitle,
        proposeSaveDisabled:
          busy ||
          this.isActionBusy ||
          !proposeTargets.length ||
          !selectedRowKeys.length ||
          (!this.tileProposeType[tileKey] &&
            (this.tileProposeValue[tileKey] === null ||
              this.tileProposeValue[tileKey] === undefined ||
              this.tileProposeValue[tileKey] === "")),
        datatableKey: tileKey + "-" + String(this._loadGeneration),
        ...actionState,
        historyOpen,
        historyLoading: historyOpen ? history.loading : false,
        historyError: historyOpen ? history.error || "" : "",
        historySections: historyOpen ? history.sections || [] : [],
        hasHistoryRows:
          historyOpen &&
          !history.loading &&
          !history.error &&
          (history.sections || []).length > 0,
        historyEmpty:
          historyOpen &&
          !history.loading &&
          !history.error &&
          !(history.sections || []).length,
        copyDisabled: busy || this.isSaving,
        deleteDisabled,
        deleteTitle
      };
    });
  }

  get isSaveDisabled() {
    return this.isLoading || this.isSaving || !this.screenRows.length;
  }

  get isBulkApplyDisabled() {
    return (
      this.isLoading ||
      this.isSaving ||
      this.isBulkApplying ||
      !this.screenRows.length
    );
  }

  get bulkPanelToggleLabel() {
    return this.showBulkPanel ? "Hide bulk update" : "Bulk update";
  }

  get bulkPanelToggleIcon() {
    return this.showBulkPanel ? "utility:chevronup" : "utility:edit";
  }

  get bulkPanelToggleTitle() {
    return "Apply field values to checked iteration rows across all products in this modal.";
  }

  handleToggleBulkPanel() {
    this.showBulkPanel = !this.showBulkPanel;
  }

  async _loadRows() {
    if (!this._lineIds.length) {
      this._resetModalState();
      return;
    }
    this.isLoading = true;
    this.historyPanel = null;
    this._resetTileState();
    try {
      const result = await loadIterations({
        lineIds: this._lineIds,
        context: this.context,
        isArchived: this.isArchived
      });
      if (result?.archivedBlocked) {
        this._toast("Error", result.excludedMessage, "error");
        this._emitClose();
        return;
      }
      this.excludedMessage = result?.excludedMessage || "";
      this.screenRows = mapLoadedIterationRows(result?.rows);
      this.bulkFeedbackMessage = "";
      this._isDirty = false;
      this._loadGeneration += 1;
      if (!this.screenRows.length) {
        this._toast(
          "Error",
          this.excludedMessage || "No Periodic products selected.",
          "error"
        );
        this._emitClose();
      }
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
      this._emitClose();
    } finally {
      this.isLoading = false;
    }
  }

  handleBulkFieldChange(event) {
    const field = event.target.dataset.field;
    const value = event.detail?.value ?? event.target.value;
    if (field === "duration") this.bulkDuration = value;
    else if (field === "notice") this.bulkNotice = value;
    else if (field === "increaseType") this.bulkIncreaseType = value;
    else if (field === "increaseValue") this.bulkIncreaseValue = value;
    else if (field === "proposedType") this.bulkProposedType = value;
    else if (field === "proposedValue") this.bulkProposedValue = value;
  }

  async handleBulkApply() {
    if (this.isBulkApplyDisabled) return;

    const bulkForm = {
      duration: this.bulkDuration,
      notice: this.bulkNotice,
      increaseType: this.bulkIncreaseType,
      increaseValue: this.bulkIncreaseValue,
      proposedType: this.bulkProposedType,
      proposedValue: this.bulkProposedValue
    };
    const bulkValidationErrors = validateBulkCommercialForm(bulkForm);
    if (bulkValidationErrors.length) {
      this._toast("Error", bulkValidationErrors[0], "error");
      return;
    }

    const template = buildBulkTemplateFromForm(bulkForm);

    if (!Object.keys(template).length) {
      this._toast("Error", "Enter at least one bulk field to apply.", "error");
      return;
    }

    const request = buildBulkApplyRequest(this.screenRows);
    if (request.missingSelection) {
      this._toast(
        "Error",
        "Check at least one iteration row in each tile you want to update.",
        "error"
      );
      return;
    }

    if (!request.scopedProductCount) {
      this._toast("Error", "No products available for bulk update.", "error");
      return;
    }

    if (request.unsavedSelected > 0) {
      this._toast(
        "Error",
        "Save new iterations before bulk update on selected rows.",
        "error"
      );
      return;
    }

    this.isBulkApplying = true;
    this.bulkFeedbackMessage = "";
    try {
      const result = await bulkApply({
        lineIds: request.lineIds,
        endDates: request.endDates,
        template,
        iterationIdsByLine: request.iterationIdsByLine
      });

      let message = result?.message || "Bulk update applied.";
      if (request.skippedCompleted > 0) {
        message +=
          " " +
          request.skippedCompleted +
          " completed row(s) in your selection were excluded.";
      }
      this.bulkFeedbackMessage = message;
      this._toast("Success", message, "success");
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isBulkApplying = false;
    }
  }

  async handleClose() {
    if (this._hasUnsavedChanges()) {
      const confirmed = await packageBuilderConfirmModal.open({
        size: "small",
        title: "Discard unsaved changes?",
        message: "Discard unsaved changes and close Iterations?",
        confirmLabel: "Discard",
        cancelLabel: "Cancel"
      });
      if (!confirmed) {
        return;
      }
    }
    this._emitClose();
  }

  _collectDatatableDraftEntries() {
    const tiles = groupScreenRowsIntoTiles(this.screenRows);
    const entries = [];
    this.template
      .querySelectorAll("c-package-builder-iterations-datatable")
      .forEach((dt) => {
        const drafts = dt.draftValues;
        if (!drafts?.length) {
          return;
        }
        const tileKey = dt.dataset.tileKey;
        const tile = tiles.find((t) => t.tileKey === tileKey);
        if (!tile) {
          return;
        }
        entries.push({
          drafts,
          anchorLineId: tile.anchorLineId,
          tileLineIds: tile.products.map((p) => p.lineId)
        });
      });
    return entries;
  }

  _mergePendingDraftsIntoScreenRows() {
    return applyAllPendingDrafts(
      this.screenRows,
      this._collectDatatableDraftEntries()
    );
  }

  _hasUnsavedChanges() {
    return (
      this._isDirty ||
      hasPendingDatatableDrafts(this._collectDatatableDraftEntries())
    );
  }

  _markDirty() {
    this._isDirty = true;
  }

  handleCloseProductPicker() {
    this.productPicker = null;
  }

  handleProductPickerSelect(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const lineId = event.currentTarget.dataset.lineId;
    const action = this.productPicker?.action;
    if (!tileKey || !lineId || !action) {
      this.productPicker = null;
      return;
    }
    this.productPicker = null;
    if (action === "history") {
      this._loadHistoryForProduct(tileKey, lineId);
    } else if (action === "revert") {
      this._runRevertForProduct(tileKey, lineId);
    }
  }

  _openProductPicker(tileKey, action) {
    this.historyPanel = null;
    this.productPicker = { tileKey, action };
  }

  handleAddRow(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const tile = groupScreenRowsIntoTiles(this.screenRows).find(
      (t) => t.tileKey === tileKey
    );
    if (!tile) return;
    this.screenRows = addIterationRowForTile(
      this.screenRows,
      tile.products.map((p) => p.lineId),
      tile.anchorLineId
    );
    this._markDirty();
  }

  /** Selection from tracked state only — safe inside reactive getters (no DOM). */
  _trackedSelectedRowKeys(tileKey, anchorRow) {
    const tracked = this.tileSelectedRowKeys[tileKey];
    if (Array.isArray(tracked) && tracked.length) {
      return tracked;
    }
    const onRow = anchorRow?.selectedRowKeys;
    if (Array.isArray(onRow) && onRow.length) {
      return onRow;
    }
    return EMPTY_ROW_KEYS;
  }

  /** Selection for action handlers; may read datatable as fallback. */
  _selectedRowKeysForTile(tileKey, anchorLineId) {
    const anchorRow = this.screenRows.find((r) => r.lineId === anchorLineId);
    const tracked = this._trackedSelectedRowKeys(tileKey, anchorRow);
    if (tracked.length) {
      return tracked;
    }
    const dt = this.template.querySelector(
      'c-package-builder-iterations-datatable[data-tile-key="' + tileKey + '"]'
    );
    if (dt && typeof dt.getSelectedRows === "function") {
      const rows = dt.getSelectedRows();
      if (rows?.length) {
        return rows.map((r) => r.rowKey || r.Id).filter(Boolean);
      }
    }
    return [];
  }

  _selectionKeysEqual(a, b) {
    const left = a || [];
    const right = b || [];
    if (left.length !== right.length) {
      return false;
    }
    for (let i = 0; i < left.length; i += 1) {
      if (left[i] !== right[i]) {
        return false;
      }
    }
    return true;
  }

  async handleDelete(event) {
    if (this.isDeleting || this.isLoading || this.isSaving) return;
    const tileKey = event.currentTarget.dataset.tileKey;
    const tile = groupScreenRowsIntoTiles(this.screenRows).find(
      (t) => t.tileKey === tileKey
    );
    if (!tile) return;

    const selectedRowKeys = this._selectedRowKeysForTile(
      tileKey,
      tile.anchorLineId
    );
    if (selectedRowKeys.length) {
      this.tileSelectedRowKeys = {
        ...this.tileSelectedRowKeys,
        [tileKey]: selectedRowKeys
      };
    }
    const anchorRow = this.screenRows.find(
      (r) => r.lineId === tile.anchorLineId
    );
    const selectedIterations = iterationsByKeys(
      anchorRow?.iterations || [],
      selectedRowKeys
    );
    if (!selectedIterations.length) {
      this._toast("Error", "Select one or more iterations to delete.", "error");
      return;
    }
    if (selectedIterations.some((it) => it.Status__c === "Completed")) {
      this._toast("Error", "Completed iterations cannot be deleted.", "error");
      return;
    }

    const tileLineIds = tile.products.map((p) => p.lineId);
    const unsavedSequences = selectedIterations
      .filter((it) => !it.Id)
      .map((it) => it.Sequence__c);
    const savedSelections = selectedIterations.filter((it) => it.Id);

    if (savedSelections.length && this._hasUnsavedChanges()) {
      this._toast(
        "Error",
        "Save or discard changes before deleting an iteration.",
        "error"
      );
      return;
    }

    if (unsavedSequences.length) {
      this.screenRows = removeIterationRowsForTile(
        this.screenRows,
        tileLineIds,
        unsavedSequences
      );
      this.tileSelectedRowKeys = { ...this.tileSelectedRowKeys, [tileKey]: [] };
      this._markDirty();
      if (!savedSelections.length) {
        return;
      }
    }

    const deleteCount = savedSelections.length;
    const confirmed = await packageBuilderConfirmModal.open({
      size: "small",
      title:
        deleteCount === 1
          ? "Delete iteration?"
          : "Delete " + String(deleteCount) + " iterations?",
      message:
        deleteCount === 1
          ? "This will remove the selected iteration and recalculate dates for all following iterations."
          : "This will remove " +
            String(deleteCount) +
            " selected iterations and recalculate dates for all following iterations.",
      confirmLabel: "Delete",
      cancelLabel: "Cancel",
      confirmVariant: "destructive"
    });
    if (!confirmed) return;

    const sequencesToDelete = new Set(
      savedSelections.map((it) => String(it.Sequence__c))
    );

    this.isDeleting = true;
    try {
      const results = await Promise.all(
        tileLineIds.map((lineId) => {
          const row = this.screenRows.find((r) => r.lineId === lineId);
          const remaining = (row?.iterations || []).filter(
            (it) =>
              it.Status__c === "Completed" ||
              !sequencesToDelete.has(String(it.Sequence__c))
          );
          return saveIterations({
            lineId,
            lineEndDate: row?.endDate,
            iterations: iterationsForSave(remaining)
          });
        })
      );
      const warned = results.some((result) => result?.noticeAlreadyDue);
      if (warned) {
        this._toast(
          "Warning",
          "Notice date is already due. Auto-renew will pick this up on the next run.",
          "warning"
        );
      } else {
        this._toast(
          "Success",
          deleteCount === 1
            ? "Iteration deleted."
            : deleteCount + " iterations deleted.",
          "success"
        );
      }
      this.dispatchEvent(new CustomEvent("saved"));
      this.tileSelectedRowKeys = {
        ...this.tileSelectedRowKeys,
        [tileKey]: []
      };
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isDeleting = false;
    }
  }

  handleRowSelection(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const anchorLineId = event.currentTarget.dataset.anchorLineId;
    const detail = event.detail || {};
    let selectedKeys = [];
    if (Array.isArray(detail.selectedRows) && detail.selectedRows.length) {
      selectedKeys = detail.selectedRows
        .map((r) => r.rowKey || r.Id)
        .filter(Boolean);
    } else if (Array.isArray(detail.selectedRowKeys)) {
      selectedKeys = detail.selectedRowKeys.filter(Boolean);
    }
    const prevKeys = this.tileSelectedRowKeys[tileKey] || [];
    if (this._selectionKeysEqual(prevKeys, selectedKeys)) {
      return;
    }
    this.tileSelectedRowKeys = {
      ...this.tileSelectedRowKeys,
      [tileKey]: selectedKeys
    };
    this.screenRows = setSelectedIterationKeys(
      this.screenRows,
      anchorLineId,
      selectedKeys
    );
  }

  handleTableSave(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const tile = groupScreenRowsIntoTiles(this.screenRows).find(
      (t) => t.tileKey === tileKey
    );
    if (!tile) return;
    this.screenRows = mergeTileDraftValues(
      this.screenRows,
      tile.products.map((p) => p.lineId),
      tile.anchorLineId,
      event.detail?.draftValues
    );
    this._markDirty();
  }

  async handleSave() {
    if (this.isSaveDisabled) return;
    this.screenRows = this._mergePendingDraftsIntoScreenRows();
    const validationErrors = validateScreenRowsCommercial(this.screenRows);
    if (validationErrors.length) {
      this._toast("Error", validationErrors[0], "error");
      return;
    }
    this.isSaving = true;
    try {
      const results = await Promise.all(
        this.screenRows.map((row) =>
          saveIterations({
            lineId: row.lineId,
            lineEndDate: row.endDate,
            iterations: iterationsForSave(row.iterations)
          })
        )
      );
      const warned = results.some((result) => result?.noticeAlreadyDue);
      if (warned) {
        this._toast(
          "Warning",
          "Notice date is already due. Auto-renew will pick this up on the next run.",
          "warning"
        );
      } else {
        this._toast("Success", "Iterations saved.", "success");
      }
      this.dispatchEvent(new CustomEvent("saved"));
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isSaving = false;
    }
  }

  async _saveProductRow(row) {
    if (!row) return null;
    return saveIterations({
      lineId: row.lineId,
      lineEndDate: row.endDate,
      iterations: iterationsForSave(row.iterations)
    });
  }

  _tileContext(event) {
    const tileKey = event.currentTarget?.dataset?.tileKey;
    const tiles = groupScreenRowsIntoTiles(this.screenRows);
    const tile = tiles.find((t) => t.tileKey === tileKey);
    if (!tile) {
      return null;
    }
    const anchorRow = this.screenRows.find(
      (r) => r.lineId === tile.anchorLineId
    );
    const selectedRowKeys = this._selectedRowKeysForTile(
      tileKey,
      tile.anchorLineId
    );
    const actionState = chipActionUiState(
      tile.productCount,
      null,
      anchorRow?.iterations || [],
      selectedRowKeys,
      false,
      tile.products[0]
    );
    return {
      tileKey,
      tile,
      selectedRowKeys,
      selectedIteration: actionState.selectedIteration,
      anchorRow
    };
  }

  _productContext(tileKey, lineId) {
    const tiles = groupScreenRowsIntoTiles(this.screenRows);
    const tile = tiles.find((t) => t.tileKey === tileKey);
    if (!tile) {
      return null;
    }
    const productRow =
      this.screenRows.find((r) => r.lineId === lineId) ||
      tile.products.find((p) => p.lineId === lineId) ||
      null;
    if (!productRow) {
      return null;
    }
    const anchorRow = this.screenRows.find(
      (r) => r.lineId === tile.anchorLineId
    );
    const selectedRowKeys = this._selectedRowKeysForTile(
      tileKey,
      tile.anchorLineId
    );
    const actionState = chipActionUiState(
      tile.productCount,
      productRow,
      anchorRow?.iterations || [],
      selectedRowKeys,
      false,
      productRow
    );
    return {
      tileKey,
      tile,
      productRow,
      selectedRowKeys,
      selectedIteration: actionState.selectedIteration,
      anchorRow
    };
  }

  async handleApprove(event) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._tileContext(event);
    if (!ctx?.anchorRow) {
      return;
    }
    const { tile, anchorRow, selectedRowKeys } = ctx;
    if (!selectedRowKeys?.length) {
      this._toast(
        "Error",
        "Select one or more iterations to approve.",
        "error"
      );
      return;
    }
    const iterationIds = resolveFanOutIterationIds(
      tile.products,
      anchorRow.iterations,
      selectedRowKeys,
      { requirePending: true }
    );
    if (!iterationIds.length) {
      this._toast(
        "Error",
        "Selected iterations must have a pending proposal.",
        "error"
      );
      return;
    }

    this.isApproving = true;
    try {
      const result = await approveIteration({ iterationIds });
      this._toast("Success", result?.message || "Approved.", "success");
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isApproving = false;
    }
  }

  handleToggleProposePanel(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const open = this.tileProposeOpen[tileKey] !== true;
    this.tileProposeOpen = { ...this.tileProposeOpen, [tileKey]: open };
    if (open) {
      const ctx = this._tileContext(event);
      if (ctx?.anchorRow && ctx.selectedRowKeys?.length) {
        const targets = resolveProposeTargetIterations(
          ctx.anchorRow.iterations,
          ctx.selectedRowKeys
        );
        const target = targets.length === 1 ? targets[0] : null;
        if (target) {
          this.tileProposeType = {
            ...this.tileProposeType,
            [tileKey]: target.Proposed_Increase_Type__c || ""
          };
          const displayVal = increaseValueForDisplay(
            target,
            "Proposed_Increase_Type__c",
            "Proposed_Increase_Percent__c",
            "Proposed_Increase_Amount__c",
            "Proposed_Final_Price__c"
          );
          this.tileProposeValue = {
            ...this.tileProposeValue,
            [tileKey]: displayVal
          };
        }
      }
    }
  }

  handleProposeFieldChange(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const field = event.currentTarget.dataset.field;
    const value = event.detail?.value ?? event.target.value;
    if (field === "type") {
      this.tileProposeType = { ...this.tileProposeType, [tileKey]: value };
    } else if (field === "value") {
      this.tileProposeValue = { ...this.tileProposeValue, [tileKey]: value };
    }
  }

  async handleSaveProposed(event) {
    if (this.isActionBusy || this.isLoading) return;
    const ctx = this._tileContext(event);
    if (!ctx?.anchorRow) {
      return;
    }

    const proposeTargets = resolveProposeTargetIterations(
      ctx.anchorRow.iterations,
      ctx.selectedRowKeys
    );
    if (!proposeTargets.length) {
      this._toast(
        "Error",
        "Select one or more open iterations to propose.",
        "error"
      );
      return;
    }

    const tileKey = ctx.tileKey;
    const proposedType = this.tileProposeType[tileKey] || "";
    const proposedValue = this.tileProposeValue[tileKey];
    if (
      proposedType &&
      (proposedValue === null ||
        proposedValue === undefined ||
        proposedValue === "")
    ) {
      this._toast(
        "Error",
        "Proposed Value is required when Proposed Type is selected.",
        "error"
      );
      return;
    }
    if (
      !proposedType &&
      (proposedValue === null ||
        proposedValue === undefined ||
        proposedValue === "")
    ) {
      this._toast("Error", "Enter a proposed type or value.", "error");
      return;
    }

    const payload = buildProposedPayload(proposedType, proposedValue);
    const iterationIds = resolveFanOutIterationIds(
      ctx.tile.products,
      ctx.anchorRow.iterations,
      ctx.selectedRowKeys
    );
    if (!iterationIds.length) {
      this._toast(
        "Error",
        "Save iterations before saving a proposed change.",
        "error"
      );
      return;
    }

    this.isActionBusy = true;
    try {
      const result = await saveProposed({ iterationIds, proposed: payload });
      const processed = Number(result?.processedCount || 0);
      this._toast(
        processed > 0 ? "Success" : "Warning",
        result?.message || "Proposed change saved.",
        processed > 0 ? "success" : "warning"
      );
      this.tileProposeOpen = { ...this.tileProposeOpen, [tileKey]: false };
      this.tileProposeType = { ...this.tileProposeType, [tileKey]: "" };
      this.tileProposeValue = { ...this.tileProposeValue, [tileKey]: null };
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async handleRejectProposed(event) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._tileContext(event);
    if (!ctx?.anchorRow) {
      return;
    }
    const { tile, anchorRow, selectedRowKeys } = ctx;
    if (!selectedRowKeys?.length) {
      this._toast("Error", "Select one or more iterations to reject.", "error");
      return;
    }
    const iterationIds = resolveFanOutIterationIds(
      tile.products,
      anchorRow.iterations,
      selectedRowKeys,
      { requirePending: true }
    );
    if (!iterationIds.length) {
      this._toast(
        "Error",
        "Selected iterations must have a pending proposal.",
        "error"
      );
      return;
    }

    this.isActionBusy = true;
    try {
      const result = await rejectProposed({ iterationIds });
      this._toast(
        "Success",
        result?.message || "Proposed change rejected.",
        "success"
      );
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async handleRevertWorking(event) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._tileContext(event);
    if (!ctx?.tile) return;
    if (ctx.tile.productCount > 1) {
      this._openProductPicker(ctx.tileKey, "revert");
      return;
    }
    await this._runRevertForProduct(ctx.tileKey, ctx.tile.products[0]?.lineId);
  }

  async _runRevertForProduct(tileKey, lineId) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._productContext(tileKey, lineId);
    if (!ctx?.productRow) return;
    const { selectedIteration, productRow } = ctx;
    if (!selectedIteration) {
      this._toast("Error", "Select one iteration first.", "error");
      return;
    }
    if (!selectedIteration.Id) {
      this._toast(
        "Error",
        "Save iterations before running this action on a new row.",
        "error"
      );
      return;
    }
    if (
      selectedIteration.Status__c === "Completed" ||
      selectedIteration.Status__c === "Inactive"
    ) {
      this._toast("Error", "Completed iterations cannot be changed.", "error");
      return;
    }
    this.productPicker = null;
    this.isActionBusy = true;
    try {
      await this._saveProductRow(productRow);
      await revertWorkingToOriginal({ iterationId: selectedIteration.Id });
      this._toast(
        "Success",
        "Working values restored from Original.",
        "success"
      );
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  async handleHistory(event) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._tileContext(event);
    if (!ctx?.tile) return;
    if (ctx.tile.productCount > 1) {
      this._openProductPicker(ctx.tileKey, "history");
      return;
    }
    await this._loadHistoryForProduct(
      ctx.tileKey,
      ctx.tile.products[0]?.lineId
    );
  }

  async _loadHistoryForProduct(tileKey, lineId) {
    if (this.isApproving || this.isLoading || this.isActionBusy) return;
    const ctx = this._productContext(tileKey, lineId);
    if (!ctx?.anchorRow || !ctx.productRow) {
      return;
    }
    const { productRow, anchorRow, selectedRowKeys } = ctx;
    if (!selectedRowKeys?.length) {
      this._toast(
        "Error",
        "Select one or more iterations to view history.",
        "error"
      );
      return;
    }
    const iterationIds = resolveHistoryIterationIds(
      productRow,
      anchorRow.iterations,
      selectedRowKeys
    );
    if (!iterationIds.length) {
      this._toast("Error", "Save iterations before viewing history.", "error");
      return;
    }

    this.productPicker = null;
    this.historyPanel = {
      tileKey,
      lineId: productRow.lineId,
      iterationIds,
      sections: [],
      loading: true,
      error: ""
    };
    try {
      const rows = await getHistoryEventsForIterations({ iterationIds });
      this.historyPanel = {
        tileKey,
        lineId: productRow.lineId,
        iterationIds,
        sections: groupHistoryEventsByIteration(rows, (d) =>
          this._formatHistoryDate(d)
        ),
        loading: false,
        error: ""
      };
    } catch (e) {
      this.historyPanel = {
        tileKey,
        lineId: productRow.lineId,
        iterationIds,
        sections: [],
        loading: false,
        error: e.body?.message || e.message || "Unable to load history."
      };
    }
  }

  handleCloseHistory() {
    this.historyPanel = null;
  }

  handleCopySourceChange(event) {
    const tileKey = event.currentTarget.dataset.tileKey;
    const value = event.detail?.value;
    this.tileCopySourceKeys = {
      ...this.tileCopySourceKeys,
      [tileKey]: value
    };
  }

  async handleCopyFrom(event) {
    if (this.isSaving || this.isLoading || this.isActionBusy) return;
    const tileKey = event.currentTarget.dataset.tileKey;

    if (!this.tileCopyFromOpen[tileKey]) {
      this.tileCopyFromOpen = { ...this.tileCopyFromOpen, [tileKey]: true };
      return;
    }

    this.screenRows = this._mergePendingDraftsIntoScreenRows();
    const tiles = groupScreenRowsIntoTiles(this.screenRows);
    const targetTile = tiles.find((t) => t.tileKey === tileKey);
    if (!targetTile) return;

    const sourceTileKey =
      this.tileCopySourceKeys[tileKey] ||
      tiles.filter((t) => t.tileKey !== tileKey).map((t) => t.tileKey)[0];
    if (!sourceTileKey) return;

    const sourceTile = tiles.find((t) => t.tileKey === sourceTileKey);
    if (!sourceTile) return;

    const sourceAnchor = this.screenRows.find(
      (r) => r.lineId === sourceTile.anchorLineId
    );
    const sourcePlan = sourceAnchor?.iterations || [];
    if (!sourcePlan.length) {
      this._toast(
        "Error",
        "Selected source has no iteration plan to copy.",
        "error"
      );
      return;
    }

    const blockedReason = copyFromBlockedReason(sourcePlan);
    if (blockedReason) {
      this._toast("Warning", blockedReason, "warning");
      return;
    }

    const copySummaries = targetTile.products
      .map((product) => {
        const row = this.screenRows.find((r) => r.lineId === product.lineId);
        if (!row) {
          return null;
        }
        return summarizeCopyFromPlan(row.iterations, sourcePlan);
      })
      .filter(Boolean);

    const copyTotals = copySummaries.reduce(
      (acc, summary) => ({
        updated: acc.updated + summary.updated,
        added: acc.added + summary.added,
        skippedLocked: acc.skippedLocked + summary.skippedLocked
      }),
      { updated: 0, added: 0, skippedLocked: 0 }
    );
    const willChange = copySummaries.some((summary) => summary.changed);

    if (!willChange) {
      this._toast("Warning", buildCopyFromResultMessage(copyTotals), "warning");
      return;
    }

    const confirmed = await packageBuilderConfirmModal.open({
      size: "small",
      title: "Copy plan from selected source?",
      message: buildCopyFromConfirmMessage(
        targetTile.productCount,
        copyTotals.skippedLocked
      ),
      confirmLabel: "Copy",
      cancelLabel: "Cancel"
    });
    if (!confirmed) return;

    this.isActionBusy = true;
    try {
      await Promise.all(
        targetTile.products.map(async (product, index) => {
          const row = this.screenRows.find((r) => r.lineId === product.lineId);
          const summary = copySummaries[index];
          if (!row || !summary?.changed) return;
          await saveIterations({
            lineId: row.lineId,
            lineEndDate: row.endDate,
            iterations: iterationsForSave(summary.merged)
          });
        })
      );
      const resultMessage = buildCopyFromResultMessage(copyTotals);
      this._toast(
        "Success",
        resultMessage,
        copyTotals.skippedLocked > 0 ? "warning" : "success"
      );
      this.tileCopyFromOpen = { ...this.tileCopyFromOpen, [tileKey]: false };
      await this._loadRows();
    } catch (e) {
      this._toast("Error", e.body?.message || e.message, "error");
    } finally {
      this.isActionBusy = false;
    }
  }

  _formatHistoryDate(value) {
    if (!value) return "";
    try {
      const d = new Date(value);
      if (Number.isNaN(d.getTime())) return String(value);
      return d.toLocaleString(undefined, {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit"
      });
    } catch {
      return String(value);
    }
  }

  _emitClose() {
    this.dispatchEvent(new CustomEvent("close"));
  }

  _toast(title, message, variant) {
    const toast = { title, message, variant };
    if (variant === "success" || variant === "info" || variant === "warning") {
      toast.mode = "dismissable";
    }
    this.dispatchEvent(new ShowToastEvent(toast));
  }
}
