import { LightningElement, api } from 'lwc';
import LightningModal from 'lightning/modal';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import AddProductsLabel from '@salesforce/label/c.PackageBuilder_AddProducts';
import NameSearchLabel from '@salesforce/label/c.AddProductsFltr_NameSearch';
import NameSearchPlaceholderLabel from '@salesforce/label/c.AddProductsFltr_NameSearchPH';

export default class AddPackageProductModal extends LightningModal {
    @api header;
    @api content;
    @api recordId;
    @api objectApiName;
    @api replaceMode = false;
    @api replacedOrderItemId;
    @api orderEndDate;   // Optional: default Period End when opening from context that has order
    @api orderStartDate; // Optional: default Period Start
    /** YYYY-MM-DD: line end date of the product being replaced (replace mode). */
    @api replacedProductEndDate;
    @api replacedActiveEndDateYmd;
    // Data is passed to api properties via .open({ options: [] })
    @api btnOptions = [];

    hasSelection = false;
    isLoading = false;
    searchKey = '';

    get nameSearchLabel() {
        return NameSearchLabel;
    }

    get nameSearchPlaceholder() {
        return NameSearchPlaceholderLabel;
    }

    connectedCallback() {
        // Hide native modal close affordances (top-right X / ESC / backdrop click)
        // so closing is controlled by explicit footer actions only.
        this.disableClose = true;
    }

    get primaryButtonLabel() {
        return this.replaceMode ? 'Replace' : AddProductsLabel;
    }

    get primaryButtonDisabled() {
        return !this.hasSelection || this.isLoading;
    }

    handleProductSelect(event) {
        const { hasSelection, isLoading } = event.detail || {};
        this.hasSelection = !!hasSelection;
        this.isLoading = !!isLoading;
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

    handleOptionClick(e) {
        const { target } = e;
        const { id } = target.dataset;
        // this.close() triggers closing the modal
        // the value of `id` is passed as the result
        console.log('id: ' + id);
        
        this.close(id);
    }

    handleAddProducts(e){
        this.close('addProducts');
    }

    handleReplaceProduct() {
        this.close('replaceProduct');
    }

    /** Child cannot show toasts reliably from inside the modal body; host re-fires here. */
    handlePackageBuilderNotify(event) {
        const { title, message, variant, mode } = event.detail || {};
        this.dispatchEvent(
            new ShowToastEvent({
                title: title || 'Notice',
                message: message || '',
                variant: variant || 'info',
                mode: mode || 'dismissable'
            })
        );
    }
}