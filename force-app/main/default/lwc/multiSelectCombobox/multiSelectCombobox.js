import { LightningElement, api, track } from 'lwc';

export default class MultiSelectCombobox extends LightningElement {
    @api label;
    @api placeholder = 'Select options';
    @api required = false;
    @api disabled = false; // Add disabled property

    @track dropdownExpanded = false;
    @track _options = [];
    @track selectedValues = [];

    connectedCallback() {
        document.addEventListener('click', this.handleDocumentClick);
    }

    disconnectedCallback() {
        document.removeEventListener('click', this.handleDocumentClick);
    }

    handleDocumentClick = (event) => {
        if (!this.template.contains(event.target)) {
            this.dropdownExpanded = false;
        }
    };

    @api
    set options(value) {
        this._options = value.map(option => ({
            ...option,
            selected: this.selectedValues.includes(option.value),
        }));
    }

    get options() {
        return this._options;
    }

    @api
    set value(val) {
        this.selectedValues = val || [];
        this._options = this._options.map(option => ({
            ...option,
            selected: this.selectedValues.includes(option.value),
        }));
    }

    get value() {
        return this.selectedValues;
    }

    get selectedOptions() {
        return this._options.filter(option => this.selectedValues.includes(option.value));
    }

    get displayValue() {
        const selectedLabels = this.selectedOptions.map(option => option.label);
        if (selectedLabels.length === 0) {
            return '';
        } else if (selectedLabels.length <= 3) {
            return selectedLabels.join(', ');
        } else {
            return `${selectedLabels.length} options selected`;
        }
    }

    toggleDropdown(event) {
        if (!this.disabled) { // Prevent toggle if disabled
            event.preventDefault();
            event.stopPropagation();
            this.dropdownExpanded = !this.dropdownExpanded;
        }
    }

    handleOptionClick(event) {
        if (this.disabled) return; // Prevent selection if disabled
        event.preventDefault();
        event.stopPropagation();
        const value = event.currentTarget.dataset.value;
        if (this.selectedValues.includes(value)) {
            this.selectedValues = this.selectedValues.filter(val => val !== value);
        } else {
            this.selectedValues = [...this.selectedValues, value];
        }
        this._options = this._options.map(option => ({
            ...option,
            selected: this.selectedValues.includes(option.value),
        }));
        this.dispatchChangeEvent();
    }

    dispatchChangeEvent() {
        const selectedValues = this.selectedValues;
        const selectedLabels = this._options
            .filter(option => selectedValues.includes(option.value))
            .map(option => option.label);

        this.dispatchEvent(
            new CustomEvent('change', {
                detail: {
                    value: selectedValues,
                    labels: selectedLabels,
                },
            })
        );
    }

    get comboboxClass() {
        return `slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click${this.dropdownExpanded ? ' slds-is-open' : ''}`;
    }
}
