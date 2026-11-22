<!--
  Copyright (C) 2022 Nethesis S.r.l.
  SPDX-License-Identifier: GPL-3.0-or-later
-->
<template>
  <cv-grid fullWidth>
    <cv-row>
      <cv-column class="page-title">
        <h2>{{ $t("settings.title") }}</h2>
      </cv-column>
    </cv-row>
    <cv-row v-if="error.getConfiguration">
      <cv-column>
        <NsInlineNotification
          kind="error"
          :title="$t('action.get-configuration')"
          :description="error.getConfiguration"
          :showCloseButton="false"
        />
      </cv-column>
    </cv-row>
    <cv-row>
      <cv-column>
        <cv-tile light>
          <cv-form @submit.prevent="configureModule">
            <cv-text-input
              :label="$t('settings.kickstart_fqdn')"
              placeholder="metabase.example.org"
              v-model.trim="host"
              class="mg-bottom"
              :invalid-message="$t(error.host)"
              :disabled="loading.getConfiguration || loading.configureModule"
              ref="host"
            >
            </cv-text-input>
            <cv-toggle
              value="letsEncrypt"
              :label="$t('settings.lets_encrypt')"
              v-model="isLetsEncryptEnabled"
              :disabled="loading.getConfiguration || loading.configureModule"
              class="mg-bottom"
            >
              <template slot="text-left">{{
                $t("settings.disabled")
              }}</template>
              <template slot="text-right">{{
                $t("settings.enabled")
              }}</template>
            </cv-toggle>
            <cv-toggle
              value="httpToHttps"
              :label="$t('settings.http_to_https')"
              v-model="isHttpToHttpsEnabled"
              :disabled="loading.getConfiguration || loading.configureModule"
              class="mg-bottom"
            >
              <template slot="text-left">{{
                $t("settings.disabled")
              }}</template>
              <template slot="text-right">{{
                $t("settings.enabled")
              }}</template>
            </cv-toggle>
            <!-- advanced options -->
            <cv-accordion ref="accordion" class="maxwidth mg-bottom">
              <cv-accordion-item :open="toggleAccordion[0]">
                <template slot="title">{{ $t("settings.advanced") }}</template>
                <template slot="content"> </template>
              </cv-accordion-item>
            </cv-accordion>
            <!-- directory login -->
            <h3 class="mg-bottom">{{ $t("settings.ldap_heading") }}</h3>
            <p class="mg-bottom maxwidth">{{ $t("settings.ldap_help") }}</p>
            <NsInlineNotification
              v-if="!loading.getConfiguration && ldapActive"
              kind="success"
              :title="$t('settings.ldap_active')"
              :description="
                $t('settings.ldap_active_description', {
                  domain: ldapSavedDomain,
                  schema: schemaLabel(ldapSchema),
                })
              "
              :showCloseButton="false"
              class="mg-bottom maxwidth"
            />
            <NsInlineNotification
              v-else-if="!loading.getConfiguration && ldapSavedDomain"
              kind="warning"
              :title="$t('settings.ldap_inactive')"
              :description="
                $t('settings.ldap_inactive_description', {
                  domain: ldapSavedDomain,
                  reason: $t(
                    'settings.' + (ldapError || 'ldap_proxy_unreachable')
                  ),
                })
              "
              :showCloseButton="false"
              class="mg-bottom maxwidth"
            />
            <NsInlineNotification
              v-else-if="!loading.getConfiguration && !ldapDomains.length"
              kind="info"
              :title="$t('settings.ldap_no_domains_title')"
              :description="$t('settings.ldap_no_domains')"
              :showCloseButton="false"
              class="mg-bottom maxwidth"
            />
            <NsComboBox
              v-model="ldapSelection"
              :title="$t('settings.ldap_domain')"
              :label="$t('settings.ldap_domain_placeholder')"
              :options="ldapOptions"
              :auto-filter="false"
              :auto-highlight="true"
              :helper-text="$t('settings.ldap_domain_help')"
              :invalid-message="error.ldap_domain"
              :disabled="loading.getConfiguration || loading.configureModule"
              light
              class="mg-bottom maxwidth"
              ref="ldap_domain"
            />
            <p
              v-if="ldapSelection && ldapSelection !== 'none'"
              class="mg-bottom maxwidth"
            >
              {{ $t("settings.ldap_signin_hint") }}
            </p>
            <!-- first administrator -->
            <h3 class="mg-bottom">{{ $t("settings.admin_heading") }}</h3>
            <NsInlineNotification
              v-if="!loading.getConfiguration && setupComplete === true"
              kind="info"
              :title="$t('settings.admin_exists_title')"
              :description="$t('settings.admin_exists')"
              :showCloseButton="false"
              class="mg-bottom maxwidth"
            />
            <template v-else>
              <p class="mg-bottom maxwidth">{{ $t("settings.admin_help") }}</p>
              <NsInlineNotification
                v-if="adminPending"
                kind="info"
                :title="$t('settings.admin_pending_title')"
                :description="
                  $t('settings.admin_pending', { email: pendingEmail })
                "
                :showCloseButton="false"
                class="mg-bottom maxwidth"
              />
              <NsTextInput
                v-model.trim="adminEmail"
                type="email"
                :label="$t('settings.admin_email')"
                placeholder="admin@example.org"
                :invalid-message="error.admin_email"
                :disabled="loading.getConfiguration || loading.configureModule"
                autocomplete="off"
                light
                class="mg-bottom maxwidth"
                ref="admin_email"
              />
              <NsTextInput
                v-model="adminPassword"
                type="password"
                :label="$t('settings.admin_password')"
                :helper-text="$t('settings.admin_password_help')"
                :invalid-message="error.admin_password"
                :disabled="loading.getConfiguration || loading.configureModule"
                autocomplete="new-password"
                light
                class="mg-bottom maxwidth"
                ref="admin_password"
              />
            </template>
            <cv-row v-if="error.configureModule">
              <cv-column>
                <NsInlineNotification
                  kind="error"
                  :title="$t('action.configure-module')"
                  :description="error.configureModule"
                  :showCloseButton="false"
                />
              </cv-column>
            </cv-row>
            <NsButton
              kind="primary"
              :icon="Save20"
              :loading="loading.configureModule"
              :disabled="loading.getConfiguration || loading.configureModule"
              >{{ $t("settings.save") }}</NsButton
            >
          </cv-form>
        </cv-tile>
      </cv-column>
    </cv-row>
  </cv-grid>
</template>

<script>
import to from "await-to-js";
import { mapState } from "vuex";
import {
  QueryParamService,
  UtilService,
  TaskService,
  IconService,
  PageTitleService,
} from "@nethserver/ns8-ui-lib";

export default {
  name: "Settings",
  mixins: [
    TaskService,
    IconService,
    UtilService,
    QueryParamService,
    PageTitleService,
  ],
  pageTitle() {
    return this.$t("settings.title") + " - " + this.appName;
  },
  data() {
    return {
      q: {
        page: "settings",
      },
      urlCheckInterval: null,
      host: "",
      isLetsEncryptEnabled: false,
      isHttpToHttpsEnabled: true,
      ldapSavedDomain: "",
      ldapSelection: "none",
      ldapDomains: [],
      ldapActive: false,
      ldapSchema: "",
      ldapError: "",
      setupComplete: null,
      adminPending: false,
      pendingEmail: "",
      adminEmail: "",
      adminPassword: "",
      loading: {
        getConfiguration: false,
        configureModule: false,
      },
      error: {
        getConfiguration: "",
        configureModule: "",
        host: "",
        lets_encrypt: "",
        http2https: "",
        ldap_domain: "",
        admin_email: "",
        admin_password: "",
      },
    };
  },
  computed: {
    ...mapState(["instanceName", "core", "appName"]),
    ldapOptions() {
      const options = [
        {
          name: "none",
          label: this.$t("settings.ldap_domain_none"),
          value: "none",
        },
      ];
      const known = this.ldapDomains.map((item) => item.name);
      if (this.ldapSavedDomain && !known.includes(this.ldapSavedDomain)) {
        // the saved domain was removed from the node: keep it visible
        options.push({
          name: this.ldapSavedDomain,
          label: this.$t("settings.ldap_domain_missing", {
            domain: this.ldapSavedDomain,
          }),
          value: this.ldapSavedDomain,
        });
      }
      for (const item of this.ldapDomains) {
        options.push({
          name: item.name,
          label: item.available
            ? `${item.name} (${this.schemaLabel(item.schema)})`
            : this.$t("settings.ldap_domain_unreachable", {
                domain: item.name,
                schema: this.schemaLabel(item.schema),
              }),
          value: item.name,
        });
      }
      return options;
    },
  },
  created() {
    this.getConfiguration();
  },
  beforeRouteEnter(to, from, next) {
    next((vm) => {
      vm.watchQueryData(vm);
      vm.urlCheckInterval = vm.initUrlBindingForApp(vm, vm.q.page);
    });
  },
  beforeRouteLeave(to, from, next) {
    clearInterval(this.urlCheckInterval);
    next();
  },
  methods: {
    async getConfiguration() {
      this.loading.getConfiguration = true;
      this.error.getConfiguration = "";
      const taskAction = "get-configuration";
      const eventId = this.getUuid();

      // register to task error
      this.core.$root.$once(
        `${taskAction}-aborted-${eventId}`,
        this.getConfigurationAborted
      );

      // register to task completion
      this.core.$root.$once(
        `${taskAction}-completed-${eventId}`,
        this.getConfigurationCompleted
      );

      const res = await to(
        this.createModuleTaskForApp(this.instanceName, {
          action: taskAction,
          extra: {
            title: this.$t("action." + taskAction),
            isNotificationHidden: true,
            eventId,
          },
        })
      );
      const err = res[0];

      if (err) {
        console.error(`error creating task ${taskAction}`, err);
        this.error.getConfiguration = this.getErrorMessage(err);
        this.loading.getConfiguration = false;
        return;
      }
    },
    getConfigurationAborted(taskResult, taskContext) {
      console.error(`${taskContext.action} aborted`, taskResult);
      this.error.getConfiguration = this.$t("error.generic_error");
      this.loading.getConfiguration = false;
    },
    getConfigurationCompleted(taskContext, taskResult) {
      const config = taskResult.output;
      this.host = config.host;
      this.isLetsEncryptEnabled = config.lets_encrypt;
      this.isHttpToHttpsEnabled = config.http2https;
      this.ldapDomains = config.ldap_domains || [];
      this.ldapSavedDomain = config.ldap_domain || "";
      this.ldapSelection = this.ldapSavedDomain || "none";
      this.ldapActive = Boolean(config.ldap_active);
      this.ldapSchema = config.ldap_schema || "";
      this.ldapError = config.ldap_error || "";
      this.setupComplete =
        config.setup_complete === undefined ? null : config.setup_complete;
      this.adminPending = Boolean(config.admin_pending);
      this.pendingEmail = config.admin_email || "";
      // the password is write-only: it is never read back
      this.adminEmail = this.pendingEmail;
      this.adminPassword = "";

      this.loading.getConfiguration = false;
      this.focusElement("host");
    },
    validateConfigureModule() {
      this.clearErrors(this);

      let isValidationOk = true;
      if (!this.host) {
        this.error.host = "common.required";

        if (isValidationOk) {
          this.focusElement("host");
        }
        isValidationOk = false;
      }
      if (this.wantsAdmin()) {
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(this.adminEmail)) {
          this.error.admin_email = this.$t("settings.admin_email_invalid");
          if (isValidationOk) {
            this.focusElement("admin_email");
          }
          isValidationOk = false;
        }
        if (!this.adminPassword) {
          this.error.admin_password = this.$t(
            "settings.admin_password_required"
          );
          if (isValidationOk) {
            this.focusElement("admin_password");
          }
          isValidationOk = false;
        } else if (
          this.adminPassword.length < 12 ||
          this.adminPassword.length > 72
        ) {
          this.error.admin_password = this.$t("settings.admin_password_length");
          if (isValidationOk) {
            this.focusElement("admin_password");
          }
          isValidationOk = false;
        }
      }
      return isValidationOk;
    },
    // the administrator fields are sent only while Metabase has no account
    wantsAdmin() {
      return (
        this.setupComplete !== true &&
        Boolean(this.adminEmail || this.adminPassword)
      );
    },
    schemaLabel(schema) {
      return schema === "ad"
        ? this.$t("settings.ldap_schema_ad")
        : this.$t("settings.ldap_schema_rfc2307");
    },
    configureModuleValidationFailed(validationErrors) {
      this.loading.configureModule = false;
      let focusAlreadySet = false;

      for (const validationError of validationErrors) {
        const param = validationError.parameter;
        // set i18n error message
        this.error[param] = this.$t("settings." + validationError.error);

        if (!focusAlreadySet) {
          this.focusElement(param);
          focusAlreadySet = true;
        }
      }
    },
    configureData() {
      const data = {
        host: this.host,
        lets_encrypt: this.isLetsEncryptEnabled,
        http2https: this.isHttpToHttpsEnabled,
        // an empty value disables the LDAP login
        ldap_domain:
          this.ldapSelection && this.ldapSelection !== "none"
            ? this.ldapSelection
            : "",
      };
      if (this.wantsAdmin()) {
        data.admin_email = this.adminEmail;
        data.admin_password = this.adminPassword;
      }
      return data;
    },
    async configureModule() {
      this.error.test_imap = false;
      this.error.test_smtp = false;
      const isValidationOk = this.validateConfigureModule();
      if (!isValidationOk) {
        return;
      }

      this.loading.configureModule = true;
      const taskAction = "configure-module";
      const eventId = this.getUuid();

      // register to task error
      this.core.$root.$once(
        `${taskAction}-aborted-${eventId}`,
        this.configureModuleAborted
      );

      // register to task validation
      this.core.$root.$once(
        `${taskAction}-validation-failed-${eventId}`,
        this.configureModuleValidationFailed
      );

      // register to task completion
      this.core.$root.$once(
        `${taskAction}-completed-${eventId}`,
        this.configureModuleCompleted
      );
      const res = await to(
        this.createModuleTaskForApp(this.instanceName, {
          action: taskAction,
          data: this.configureData(),
          extra: {
            title: this.$t("settings.instance_configuration", {
              instance: this.instanceName,
            }),
            description: this.$t("settings.configuring"),
            eventId,
          },
        })
      );
      const err = res[0];

      if (err) {
        console.error(`error creating task ${taskAction}`, err);
        this.error.configureModule = this.getErrorMessage(err);
        this.loading.configureModule = false;
        return;
      }
    },
    configureModuleAborted(taskResult, taskContext) {
      console.error(`${taskContext.action} aborted`, taskResult);
      this.error.configureModule = this.$t("error.generic_error");
      this.loading.configureModule = false;
    },
    configureModuleCompleted() {
      this.loading.configureModule = false;

      // reload configuration
      this.getConfiguration();
    },
  },
};
</script>

<style scoped lang="scss">
@import "../styles/carbon-utils";
.mg-bottom {
  margin-bottom: $spacing-06;
}

.maxwidth {
  max-width: 38rem;
}
</style>
