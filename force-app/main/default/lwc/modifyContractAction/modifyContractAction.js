import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getActiveContracts from '@salesforce/apex/ModifyContractActionController.getActiveContracts';

export default class ModifyContractAction extends NavigationMixin(LightningElement) {
    _recordId;
    loadedForRecordId;

    @track loading = true;
    @track errorMessage = '';
    @track contracts = [];
    @track selectedContractId;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value && this.loadedForRecordId !== value) {
            this.loadedForRecordId = value;
            this.loadActiveContracts();
        }
    }

    get hasError() {
        return this.errorMessage !== '';
    }

    get showNotFound() {
        return !this.loading && !this.hasError && this.contracts.length === 0;
    }

    get showSelector() {
        return !this.loading && !this.hasError && this.contracts.length > 1;
    }

    get contractRows() {
        return this.contracts.map((item) => ({
            ...item,
            locationNameLabel: item.locationName ? item.locationName : 'No location',
            selected: this.selectedContractId === item.contractId
        }));
    }

    get disableOpenButton() {
        return !this.selectedContractId;
    }

    handleSelectionChange(event) {
        this.selectedContractId = event.target.dataset.id;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleOpenContract() {
        if (this.selectedContractId) {
            this.navigateToContract(this.selectedContractId);
        }
    }

    async loadActiveContracts() {
        if (!this.recordId) {
            return;
        }

        this.loading = true;
        this.errorMessage = '';

        try {
            const results = await getActiveContracts({ accountId: this.recordId });
            this.contracts = Array.isArray(results) ? results : [];

            if (this.contracts.length === 1) {
                this.navigateToContract(this.contracts[0].contractId);
                return;
            }
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
        } finally {
            this.loading = false;
        }
    }

    navigateToContract(contractId) {
        this.dispatchEvent(new CloseActionScreenEvent());
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: contractId,
                objectApiName: 'Contract',
                actionName: 'view'
            }
        });
    }

    normalizeError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (Array.isArray(error?.body) && error.body.length > 0) {
            return error.body.map((entry) => entry.message).join(', ');
        }
        if (error?.message) {
            return error.message;
        }
        return 'An unexpected error occurred while loading active contracts.';
    }
}