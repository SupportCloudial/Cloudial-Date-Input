import { api } from "lwc";
import LightningModal from "lightning/modal";

export default class PackageBuilderConfirmModal extends LightningModal {
  @api title = "Confirm";
  @api message = "";
  @api confirmLabel = "OK";
  @api cancelLabel = "Cancel";
  @api confirmVariant = "brand";

  handleCancel() {
    this.close(false);
  }

  handleConfirm() {
    this.close(true);
  }
}
