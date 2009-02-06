namespace :rpx do
  desc "Unmaps all user mappings for the current environment and drops them from the database"
  task :unmap => :environment do
    @rpx = Rpx::RpxHelper.new(RPX_API_KEY, RPX_BASE_URL, RPX_REALM)
    @users = User.find(:all)
    
    for user in @users
      identifiers = @rpx.mappings(user.id)
      # clear all identifiers
      for identifier in identifiers
        @rpx.unmap(identifier, user.id)
        puts "Mapping #{user.id} => #{identifier} removed"
      end
      user.destroy
    end
  end
end