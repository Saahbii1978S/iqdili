export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      admin_notification_events: {
        Row: {
          created_at: string
          event_type: string
          user_id: string
        }
        Insert: {
          created_at?: string
          event_type: string
          user_id: string
        }
        Update: {
          created_at?: string
          event_type?: string
          user_id?: string
        }
        Relationships: []
      }
      admin_role_events: {
        Row: {
          action: string
          actor_id: string | null
          created_at: string
          id: number
          target_user_id: string | null
        }
        Insert: {
          action: string
          actor_id?: string | null
          created_at?: string
          id?: never
          target_user_id?: string | null
        }
        Update: {
          action?: string
          actor_id?: string | null
          created_at?: string
          id?: never
          target_user_id?: string | null
        }
        Relationships: []
      }
      admin_status_audit: {
        Row: {
          actor_id: string | null
          changed_at: string
          id: number
          new_status: string | null
          old_status: string | null
          record_id: string
          table_name: string
        }
        Insert: {
          actor_id?: string | null
          changed_at?: string
          id?: never
          new_status?: string | null
          old_status?: string | null
          record_id: string
          table_name: string
        }
        Update: {
          actor_id?: string | null
          changed_at?: string
          id?: never
          new_status?: string | null
          old_status?: string | null
          record_id?: string
          table_name?: string
        }
        Relationships: []
      }
      admins: {
        Row: {
          user_id: string
        }
        Insert: {
          user_id: string
        }
        Update: {
          user_id?: string
        }
        Relationships: []
      }
      job_posts: {
        Row: {
          city: string | null
          contact_public: boolean
          created_at: string | null
          description: string | null
          expires_at: string | null
          id: number
          image_urls: string[]
          job_type: string | null
          phone: string | null
          status: string
          title: string
          user_id: string | null
          work_nature: string | null
        }
        Insert: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          job_type?: string | null
          phone?: string | null
          status?: string
          title: string
          user_id?: string | null
          work_nature?: string | null
        }
        Update: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          job_type?: string | null
          phone?: string | null
          status?: string
          title?: string
          user_id?: string | null
          work_nature?: string | null
        }
        Relationships: []
      }
      jobs: {
        Row: {
          ad_type: string | null
          contact_info: string | null
          created_at: string | null
          details_salary: string | null
          id: number
          job_title: string | null
          job_type: string | null
          region: string | null
        }
        Insert: {
          ad_type?: string | null
          contact_info?: string | null
          created_at?: string | null
          details_salary?: string | null
          id?: number
          job_title?: string | null
          job_type?: string | null
          region?: string | null
        }
        Update: {
          ad_type?: string | null
          contact_info?: string | null
          created_at?: string | null
          details_salary?: string | null
          id?: number
          job_title?: string | null
          job_type?: string | null
          region?: string | null
        }
        Relationships: []
      }
      market: {
        Row: {
          ad_type: string | null
          category: string | null
          contact_phone: string | null
          created_at: string | null
          description: string | null
          id: number
          price: number | null
          product_name: string | null
          region: string | null
        }
        Insert: {
          ad_type?: string | null
          category?: string | null
          contact_phone?: string | null
          created_at?: string | null
          description?: string | null
          id?: number
          price?: number | null
          product_name?: string | null
          region?: string | null
        }
        Update: {
          ad_type?: string | null
          category?: string | null
          contact_phone?: string | null
          created_at?: string | null
          description?: string | null
          id?: number
          price?: number | null
          product_name?: string | null
          region?: string | null
        }
        Relationships: []
      }
      market_posts: {
        Row: {
          category: string | null
          city: string | null
          contact_public: boolean
          created_at: string | null
          description: string | null
          expires_at: string | null
          id: number
          image_urls: string[]
          listing_type: string | null
          phone: string | null
          price: number | null
          status: string
          title: string
          user_id: string | null
        }
        Insert: {
          category?: string | null
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: number
          image_urls?: string[]
          listing_type?: string | null
          phone?: string | null
          price?: number | null
          status?: string
          title: string
          user_id?: string | null
        }
        Update: {
          category?: string | null
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: number
          image_urls?: string[]
          listing_type?: string | null
          phone?: string | null
          price?: number | null
          status?: string
          title?: string
          user_id?: string | null
        }
        Relationships: []
      }
      properties: {
        Row: {
          area: number | null
          contact_info: string | null
          created_at: string | null
          description: string | null
          id: number
          price: number | null
          process_type: string | null
          property_type: string | null
          region: string | null
          rooms_count: number | null
        }
        Insert: {
          area?: number | null
          contact_info?: string | null
          created_at?: string | null
          description?: string | null
          id?: number
          price?: number | null
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number | null
        }
        Update: {
          area?: number | null
          contact_info?: string | null
          created_at?: string | null
          description?: string | null
          id?: number
          price?: number | null
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number | null
        }
        Relationships: []
      }
      real_estate_posts: {
        Row: {
          city: string | null
          contact_public: boolean
          created_at: string | null
          description: string | null
          expires_at: string | null
          id: number
          image_urls: string[]
          listing_type: string | null
          phone: string | null
          price: number | null
          property_type: string | null
          rooms: number | null
          size: number | null
          status: string
          title: string
          user_id: string | null
        }
        Insert: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          listing_type?: string | null
          phone?: string | null
          price?: number | null
          property_type?: string | null
          rooms?: number | null
          size?: number | null
          status?: string
          title: string
          user_id?: string | null
        }
        Update: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          listing_type?: string | null
          phone?: string | null
          price?: number | null
          property_type?: string | null
          rooms?: number | null
          size?: number | null
          status?: string
          title?: string
          user_id?: string | null
        }
        Relationships: []
      }
      realty: {
        Row: {
          area: number
          contact_info: string | null
          created_at: string
          description: string | null
          id: number
          price: number
          process_type: string | null
          property_type: string | null
          region: string | null
          rooms_count: number
        }
        Insert: {
          area?: number
          contact_info?: string | null
          created_at?: string
          description?: string | null
          id?: number
          price?: number
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number
        }
        Update: {
          area?: number
          contact_info?: string | null
          created_at?: string
          description?: string | null
          id?: number
          price?: number
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number
        }
        Relationships: []
      }
      service_requests: {
        Row: {
          city: string | null
          contact_public: boolean
          created_at: string | null
          description: string | null
          expires_at: string | null
          id: number
          image_urls: string[]
          phone: string | null
          status: string
          title: string
          user_id: string | null
        }
        Insert: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          phone?: string | null
          status?: string
          title: string
          user_id?: string | null
        }
        Update: {
          city?: string | null
          contact_public?: boolean
          created_at?: string | null
          description?: string | null
          expires_at?: string | null
          id?: never
          image_urls?: string[]
          phone?: string | null
          status?: string
          title?: string
          user_id?: string | null
        }
        Relationships: []
      }
      services: {
        Row: {
          created_at: string | null
          details: string | null
          id: number
          phone: string | null
          region: string | null
          service_type: string | null
          suitable_time: string | null
        }
        Insert: {
          created_at?: string | null
          details?: string | null
          id?: number
          phone?: string | null
          region?: string | null
          service_type?: string | null
          suitable_time?: string | null
        }
        Update: {
          created_at?: string | null
          details?: string | null
          id?: number
          phone?: string | null
          region?: string | null
          service_type?: string | null
          suitable_time?: string | null
        }
        Relationships: []
      }
      staff_roles: {
        Row: {
          granted_at: string
          granted_by: string | null
          role: string
          user_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          role?: string
          user_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          role?: string
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      approved_market_posts: {
        Row: {
          category: string | null
          city: string | null
          created_at: string | null
          description: string | null
          id: number | null
          listing_type: string | null
          price: number | null
          title: string | null
        }
        Insert: {
          category?: string | null
          city?: string | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          listing_type?: string | null
          price?: number | null
          title?: string | null
        }
        Update: {
          category?: string | null
          city?: string | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          listing_type?: string | null
          price?: number | null
          title?: string | null
        }
        Relationships: []
      }
      jobs_public: {
        Row: {
          ad_type: string | null
          created_at: string | null
          details_salary: string | null
          id: number | null
          job_title: string | null
          job_type: string | null
          region: string | null
        }
        Insert: {
          ad_type?: string | null
          created_at?: string | null
          details_salary?: string | null
          id?: number | null
          job_title?: string | null
          job_type?: string | null
          region?: string | null
        }
        Update: {
          ad_type?: string | null
          created_at?: string | null
          details_salary?: string | null
          id?: number | null
          job_title?: string | null
          job_type?: string | null
          region?: string | null
        }
        Relationships: []
      }
      market_public: {
        Row: {
          ad_type: string | null
          category: string | null
          created_at: string | null
          description: string | null
          id: number | null
          price: number | null
          product_name: string | null
          region: string | null
        }
        Insert: {
          ad_type?: string | null
          category?: string | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          price?: number | null
          product_name?: string | null
          region?: string | null
        }
        Update: {
          ad_type?: string | null
          category?: string | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          price?: number | null
          product_name?: string | null
          region?: string | null
        }
        Relationships: []
      }
      realty_public: {
        Row: {
          area: number | null
          created_at: string | null
          description: string | null
          id: number | null
          price: number | null
          process_type: string | null
          property_type: string | null
          region: string | null
          rooms_count: number | null
        }
        Insert: {
          area?: number | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          price?: number | null
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number | null
        }
        Update: {
          area?: number | null
          created_at?: string | null
          description?: string | null
          id?: number | null
          price?: number | null
          process_type?: string | null
          property_type?: string | null
          region?: string | null
          rooms_count?: number | null
        }
        Relationships: []
      }
      services_public: {
        Row: {
          created_at: string | null
          details: string | null
          id: number | null
          region: string | null
          service_type: string | null
          suitable_time: string | null
        }
        Insert: {
          created_at?: string | null
          details?: string | null
          id?: number | null
          region?: string | null
          service_type?: string | null
          suitable_time?: string | null
        }
        Update: {
          created_at?: string | null
          details?: string | null
          id?: number | null
          region?: string | null
          service_type?: string | null
          suitable_time?: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      admin_list_status_audit: {
        Args: never
        Returns: {
          actor_email: string
          changed_at: string
          new_status: string
          old_status: string
          record_id: string
          table_name: string
        }[]
      }
      admin_list_users: {
        Args: never
        Returns: {
          created_at: string
          email: string
          is_moderator: boolean
          last_sign_in_at: string
          user_id: string
        }[]
      }
      admin_set_moderator: {
        Args: { p_make_moderator: boolean; p_user_id: string }
        Returns: boolean
      }
      consume_ask_rate_limit: {
        Args: { p_fingerprint: string }
        Returns: boolean
      }
      consume_pending_image_rate_limit: {
        Args: { p_fingerprint: string }
        Returns: boolean
      }
      get_site_visitor_stats: {
        Args: never
        Returns: {
          online_now: number
          total_visits: number
          visitors_today: number
        }[]
      }
      is_admin: { Args: never; Returns: boolean }
      is_owner: { Args: never; Returns: boolean }
      public_job_posts: {
        Args: never
        Returns: {
          city: string
          created_at: string
          description: string
          id: number
          image_urls: string[]
          job_type: string
          phone: string
          title: string
          work_nature: string
        }[]
      }
      public_market_posts: {
        Args: never
        Returns: {
          category: string
          city: string
          created_at: string
          description: string
          id: number
          image_urls: string[]
          listing_type: string
          phone: string
          price: number
          title: string
        }[]
      }
      public_real_estate_posts: {
        Args: never
        Returns: {
          city: string
          created_at: string
          description: string
          id: number
          image_urls: string[]
          listing_type: string
          phone: string
          price: number
          property_type: string
          rooms: number
          size: number
          title: string
        }[]
      }
      public_service_requests: {
        Args: never
        Returns: {
          city: string
          created_at: string
          description: string
          id: number
          image_urls: string[]
          phone: string
          title: string
        }[]
      }
      record_site_visit:
        | { Args: never; Returns: undefined }
        | { Args: { p_visitor_id: string }; Returns: undefined }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
