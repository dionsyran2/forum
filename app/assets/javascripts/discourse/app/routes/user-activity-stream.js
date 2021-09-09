import DiscourseRoute from "discourse/routes/discourse";
import ViewingActionType from "discourse/mixins/viewing-action-type";
import { action } from "@ember/object";

export default DiscourseRoute.extend(ViewingActionType, {
  queryParams: {
    acting_username: { refreshModel: true },
  },

  model() {
    const streamModel = this.modelFor("user").get("stream");
    streamModel.set("emptyStateBody", this.emptyStateBody);
    streamModel.set("emptyStateTitle", this.emptyStateTitle);
    return streamModel;
  },

  afterModel(model, transition) {
    return model.filterBy({
      filter: this.userActionType,
      noContentHelpKey: this.noContentHelpKey || "user_activity.no_default",
      actingUsername: transition.to.queryParams.acting_username,
    });
  },

  renderTemplate() {
    this.render("user_stream");
  },

  setupController(controller, model) {
    controller.set("model", model);
    this.viewingActionType(this.userActionType);
  },

  @action
  didTransition() {
    this.controllerFor("user-activity")._showFooter();
    return true;
  },
});
