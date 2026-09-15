import { api, LightningElement } from 'lwc';
import NameSearchLabel from '@salesforce/label/c.AddProductsFltr_NameSearch';
import NameSearchPlaceholderLabel from '@salesforce/label/c.AddProductsFltr_NameSearchPH';

export default class PackageBuilderAddProductsSheet extends LightningElement {
    @api isOpen = false;
    @api sessionKey;
    @api recordId;
    @api objectApiName;
    @api replaceMode = false;
    @api replacedOrderItemId;
    @api replacedPricebookEntryId;
    @api orderStartDate;
    @api orderEndDate;
    /** YYYY-MM-DD: Package Builder replace — max(contract start, replaced line start) for Period Start default. */
    @api replaceDefaultPeriodStartYmd;
    @api replacedProductEndDate;
    @api replacedActiveEndDateYmd;
    @api addProductsLabel = 'Add Products';
    @api cancelLabel = 'Cancel';

    hasSelection = false;
    isLoading = false;
    searchKey = '';
    _lastFocusedOpenState = false;

    get backdropClass() {
        return `add-products-sheet-backdrop${this.isOpen ? ' is-open' : ''}`;
    }

    get sheetClass() {
        return `add-products-sheet${this.isOpen ? ' is-open' : ''}`;
    }

    get ariaHidden() {
        return this.isOpen ? 'false' : 'true';
    }

    get headerLabel() {
        return this.replaceMode ? 'Replace Product' : this.addProductsLabel;
    }

    get primaryButtonLabel() {
        return this.replaceMode ? 'Replace' : this.addProductsLabel;
    }

    get primaryButtonDisabled() {
        return !this.hasSelection || this.isLoading;
    }

    get nameSearchLabel() {
        return NameSearchLabel;
    }

    get nameSearchPlaceholder() {
        return NameSearchPlaceholderLabel;
    }

    renderedCallback() {
        if (!this.isOpen) {
            this._lastFocusedOpenState = false;
            // Reset footer state so next open doesn't inherit stale selection/loading.
            this.hasSelection = false;
            this.isLoading = false;
            return;
        }
        const el = this.template.querySelector('[data-add-products-close]');
        if (el && this._lastFocusedOpenState !== true) {
            el.focus();
            this._lastFocusedOpenState = true;
        }
    }

    handleBackdropClick() {
        this.handleClose();
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleKeydown(event) {
        if (!this.isOpen) return;
        if (event.key === 'Escape') {
            event.preventDefault();
            this.handleClose();
        }
    }

    handlePrimaryClick() {
        const child = this.template.querySelector('c-add-package-product');
        if (child && typeof child.submit === 'function') {
            child.submit();
        }
    }

    handleHeaderSearchChange(event) {
        const raw = event?.detail?.value ?? '';
        this.searchKey = raw;
        const child = this.template.querySelector('c-add-package-product');
        if (child && typeof child.updateSearchKey === 'function') {
            child.updateSearchKey(raw);
        }
    }

    handleProductSelect(event) {
        const { hasSelection, isLoading } = event.detail || {};
        this.hasSelection = !!hasSelection;
        this.isLoading = !!isLoading;
    }

    handleComplete() {
        this.dispatchEvent(new CustomEvent('complete'));
    }

    handleNotify(event) {
        this.dispatchEvent(
            new CustomEvent('notify', {
                detail: event.detail
            })
        );
    }
}