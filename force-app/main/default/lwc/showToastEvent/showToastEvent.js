import { LightningElement, api, track } from 'lwc';

export default class ShowToastEvent extends LightningElement {
    @api toastTitle;
    @api toastType;


    get toastClasses() {
        return `slds-notify slds-notify_toast slds-theme_${this.toastType}`;
    }

    get iconClasses() {
        return 'slds-icon_container slds-m-horizontal_small slds-no-flex slds-align-top';
    }

    get iconTitle() {
        return `Description of icon when needed for ${this.toastType}`;
    }

    get iconPath() {
        // Déterminer le chemin de l'icône en fonction du type de toast
        if (this.toastType === 'success') {
            return './icons/utility-sprite/svg/symbols.svg#success';
        } else if (this.toastType === 'error') {
            return './icons/utility-sprite/svg/symbols.svg#error';
        } else if (this.toastType === 'warning') {
            return './icons/utility-sprite/svg/symbols.svg#warning';
        }
    
        // Par défaut, utiliser une icône générique
        return './icons/utility-sprite/svg/symbols.svg#info';
    }

    closeToast() {
        // Émettre un événement pour demander la fermeture du toast
        this.dispatchEvent(new CustomEvent('closetoast'));
    }
}