import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import './index.css'
import { BASE_PATH } from './config'
import Landing from './Landing'
import ProfilePage from './pages/ProfilePage'
import WalletPage from './pages/WalletPage'
import MyBetsPage from './pages/MyBetsPage'
import ExplorePage from './pages/ExplorePage'
import DashboardPage from './pages/DashboardPage'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <BrowserRouter basename={BASE_PATH}>
      <Routes>
        <Route path="/" element={<Landing />} />
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/wallet" element={<WalletPage />} />
        <Route path="/mybets" element={<MyBetsPage />} />
        <Route path="/explore" element={<ExplorePage />} />
        <Route path="/dashboard" element={<DashboardPage />} />
      </Routes>
    </BrowserRouter>
  </StrictMode>,
)
