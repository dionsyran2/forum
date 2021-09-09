import DiscourseRoute from "discourse/routes/discourse";
import I18n from "I18n";

export default DiscourseRoute.extend({
  emptyStateTitle: I18n.t("user_activity.no_drafts_title"),
  emptyStateBody: I18n.t("user_activity.no_drafts_body"),

  model() {
    const userDraftsStream = this.modelFor("user").get("userDraftsStream");
    userDraftsStream.set("emptyStateBody", this.emptyStateBody);
    userDraftsStream.set("emptyStateTitle", this.emptyStateTitle);
    return userDraftsStream.load(this.site).then(() => userDraftsStream);
  },

  renderTemplate() {
    this.render("user_stream");
  },

  setupController(controller, model) {
    controller.set("model", model);
  },

  activate() {
    this.appEvents.on("draft:destroyed", this, this.refresh);
  },

  deactivate() {
    this.appEvents.off("draft:destroyed", this, this.refresh);
  },

  actions: {
    didTransition() {
      this.controllerFor("user-activity")._showFooter();
      return true;
    },
  },
});
