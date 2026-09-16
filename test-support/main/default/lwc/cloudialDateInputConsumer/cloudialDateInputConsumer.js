import { LightningElement } from "lwc";

export default class CloudialDateInputConsumer extends LightningElement {
  selectedDate = "";

  handleDateChange(event) {
    this.selectedDate = event.detail.value;
  }
}
