import { LightningElement, api } from "lwc";

export default class PackageBuilderKpiPanel extends LightningElement {
  @api expanded = false;
  /** When true, show Closed Won read-only notice in the Summary header row (between title and expand toggle). */
  @api showHeaderReadOnlyNotice = false;
  @api headerReadOnlyNoticeMessage = "";
  @api summary = {
    totalMonthlyRoomsRevenue: 0,
    averageMonthlyDesksRevenue: 0,
    totalCalculatedMonthlyRoomsRevenue: 0,
    deskCount: 0,
    totalCalculatedRevenueAllRooms: 0,
    totalMonthlyParkingRevenue: 0,
    averageMonthlyParkingRevenue: 0,
    parkingSpots: 0
  };
  @api totalProducts = 0;

  handleToggle() {
    this.dispatchEvent(new CustomEvent("kpitoggle"));
  }
}
